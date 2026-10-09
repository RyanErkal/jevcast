import Foundation

/// Keeps one account's mail on this Mac in step with its server. It uses three connections: one
/// for sync, one for changes you make, so they never wait behind a long sync, and one that waits
/// in IDLE for new mail. Only the newest mail of the inbox and of folders you open is read. Older
/// mail comes when the list scrolls to it, and other bodies when a message opens.
public actor MailAccountSync {
    public enum State: Sendable, Equatable {
        case starting
        case syncing
        case ready(Date)
        /// Sync stopped. `signIn` is true when the server refused the password or token: sync then
        /// waits for new details instead of trying again, so the server does not lock the account.
        case failed(String, signIn: Bool)
    }

    public nonisolated let account: NativeMailAccount
    let store: NativeMailStore
    let policy: MailSyncPolicy
    let syncClient: IMAPClient
    let actionClient: IMAPClient
    let idleClient: IMAPClient
    let smtp: SMTPClient
    let changed: @Sendable () -> Void
    /// The store revision last announced, so a pass that changed nothing stays quiet.
    private var announced = -1
    private let report: @Sendable (String, State) -> Void
    let notice: @Sendable (String, String) -> Void
    let signal = MailSyncSignal()
    private var loop: Task<Void, Never>?
    private var idler: Task<Void, Never>?
    var mailboxes: [NativeMailStore.Mailbox] = []
    private var listedAt: Date?
    private var countedAt: Date?
    /// Non-CONDSTORE servers are checked in rotating bounded batches. A server with CONDSTORE
    /// can return only changed flags, so it still scans all cached ranges without downloading
    /// unchanged rows.
    /// Last UID checked in a rotating large-folder pass. Keeping a UID rather than an array index
    /// means expunges do not force a full mailbox allocation or invalidate the next page.
    private var flagCursor: [Int64: UInt32] = [:]
    public private(set) var state: State = .starting

    public init(account: NativeMailAccount, store: NativeMailStore, policy: MailSyncPolicy = MailSyncPolicy(),
                credential: @escaping @Sendable () async throws -> MailCredential,
                transport: @escaping IMAPClient.TransportFactory = IMAPClient.networkTransport,
                changed: @escaping @Sendable () -> Void = {}, report: @escaping @Sendable (String, State) -> Void = { _, _ in },
                notice: @escaping @Sendable (String, String) -> Void = { _, _ in }) {
        self.account = account
        self.store = store
        self.policy = policy
        let imap = IMAPClient.Settings(server: account.imap, username: account.imapUsername)
        syncClient = IMAPClient(settings: imap, credential: credential, transport: transport)
        actionClient = IMAPClient(settings: imap, credential: credential, transport: transport)
        idleClient = IMAPClient(settings: imap, credential: credential, transport: transport)
        smtp = SMTPClient(settings: .init(server: account.smtp, username: account.smtpUsername), credential: credential, transport: transport)
        self.changed = changed
        self.report = report
        self.notice = notice
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() async {
        loop?.cancel(); idler?.cancel()
        loop = nil; idler = nil
        await signal.cancel()
        await syncClient.logout()
        await actionClient.logout()
        await idleClient.logout()
    }

    public func request(_ request: MailSyncRequest) async { await signal.post(request) }

    /// After sleep or a network change: new connections, a new IDLE, and a full check now.
    public func wake() async {
        guard loop != nil else { return }
        idler?.cancel()
        idler = nil
        await syncClient.drop()
        await actionClient.drop()
        await signal.post(.everything)
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        report(account.id, new)
    }

    // MARK: The loop

    enum PassOutcome { case done(more: Bool), signIn, failed, cancelled }

    private func run() async {
        var request = MailSyncRequest.everything
        var failures = 0
        while !Task.isCancelled {
            switch await pass(request) {
            case .done(let more):
                failures = 0
                // Read-ahead bodies come in short steps; new mail from IDLE still comes first.
                if more { request = await signal.wait(timeout: 0.5) ?? MailSyncRequest() }
                else { request = await signal.wait(timeout: policy.periodic) ?? .everything }
            case .signIn:
                idler?.cancel(); idler = nil
                await idleClient.drop()
                return
            case .failed:
                failures += 1
                request = await signal.wait(timeout: min(600, 10 * pow(2, Double(min(failures, 6))))) ?? .everything
            case .cancelled:
                return
            }
        }
    }

    func pass(_ request: MailSyncRequest) async -> PassOutcome {
        // Background steps (older mail, bodies) do not change what Settings shows.
        let visible = request.all || request.inbox || !request.mailboxes.isEmpty
        if visible { setState(.syncing) }
        do {
            if mailboxes.isEmpty || (request.all && listedAt.map { Date().timeIntervalSince($0) > policy.listing } ?? true) {
                try await list()
            }
            startIdleIfNeeded()
            let now = Date()
            // A folder is read once it has been opened; until then it costs nothing.
            let targets = mailboxes.filter { box in
                (request.all && (box.role == .inbox || box.uidValidity != nil))
                    || (request.inbox && box.role == .inbox) || request.mailboxes.contains(box.rowID)
            }
            for box in targets {
                try Task.checkCancellation()
                let interval = box.role == .inbox ? policy.inboxFullCheck : policy.fullCheck
                let full = box.lastFullCheck.map { now.timeIntervalSince($0) >= interval } ?? true
                try await sync(box, full: full)
                await announce()
            }
            if visible { await refreshServerCounts() }
            let more = try await prefetchBodies()
            let offlineMore = try await runOfflineWork()
            await replayOfflineActions()
            if case .ready = state, !visible {} else { setState(.ready(Date())) }
            return .done(more: more || offlineMore)
        } catch is CancellationError {
            return .cancelled
        } catch MailError.uidValidityChanged {
            // A full pass selects the mailbox again, sees the new UIDVALIDITY, and reads it from the start.
            listedAt = nil
            await signal.post(.everything)
            return .done(more: true)
        } catch let error as MailError {
            if case .signInFailed = error { setState(.failed(error.localizedDescription, signIn: true)); return .signIn }
            setState(.failed(error.localizedDescription, signIn: false))
            return .failed
        } catch {
            if Task.isCancelled { return .cancelled }
            setState(.failed(error.localizedDescription, signIn: false))
            return .failed
        }
    }

    private func list() async throws {
        let entries = try await syncClient.listMailboxes()
        mailboxes = try await store.replaceMailboxes(account: account.id, with: entries, roles: account.mailboxRoles ?? [:])
        listedAt = Date()
        await announce()
    }

    /// The server's message and unread counts for every mailbox, at most once a minute: one LIST
    /// with LIST-STATUS, or one STATUS per mailbox. Counts are a view aid, so a failure is left for the next pass.
    private func refreshServerCounts() async {
        if let countedAt, Date().timeIntervalSince(countedAt) < 60 { return }
        countedAt = Date()
        var counts: [Int64: (total: Int, unread: Int)] = [:]
        if await syncClient.has("LIST-STATUS"), let all = try? await syncClient.listStatus() {
            for box in mailboxes { if let count = all[box.name] { counts[box.rowID] = (count.messages, count.unseen) } }
        } else {
            for box in mailboxes {
                guard !Task.isCancelled, let count = try? await syncClient.status(box.name) else { continue }
                counts[box.rowID] = (count.messages, count.unseen)
            }
        }
        try? await store.setServerCounts(counts)
        await announce()
    }

    /// Tells the app about store changes, once per step, and only when something changed.
    func announce() async {
        let revision = await store.revision
        guard revision != announced else { return }
        announced = revision
        changed()
    }

    func replace(_ box: NativeMailStore.Mailbox) {
        if let index = mailboxes.firstIndex(where: { $0.rowID == box.rowID }) { mailboxes[index] = box }
    }

    private func items(_ client: IMAPClient) async -> String { SyncedMessage.fetchItems(gmail: await client.has("X-GM-EXT-1")) }

    // MARK: One mailbox

    /// New mail, then flag changes, then removed messages. Only new mail costs a download.
    func sync(_ original: NativeMailStore.Mailbox, full: Bool) async throws {
        var box = original
        let offlineStorage = try await store.offlinePolicy(for: account.id)
        let info: IMAPClient.MailboxInfo
        do { info = try await syncClient.select(box.name) } catch MailError.commandFailed(_, .no, _) {
            // The mailbox went away or cannot be opened; the next listing decides.
            listedAt = nil
            return
        }
        if let known = box.uidValidity, known != info.uidValidity {
            box = try await store.reset(box, uidValidity: info.uidValidity)
        }
        box.uidValidity = info.uidValidity
        let validity = info.uidValidity
        let items = await items(syncClient)
        // Search-only hits can leave rows in the store before normal history is seeded. The
        // persisted UIDNEXT and history floor are the normal-sync watermarks; never infer either
        // from the highest or lowest cached row.
        let firstSync = box.uidNext == nil || box.historyFloorUID == nil
        let priorUIDNext = box.uidNext

        if firstSync {
            if info.exists > 0 {
                let baseCount = box.role == .inbox ? policy.firstInbox : policy.firstOther
                let count = offlineStorage.mode == .recent ? min(baseCount, offlineStorage.recentMessageLimit) : baseCount
                if count > 0 {
                    let newest = try await newestUIDs(count, below: info.uidNext ?? .max, above: 0, in: box.name, validity: validity, client: syncClient)
                    try await fetchHeaders(newest.uids, into: box, validity: validity, items: items, client: syncClient)
                    box.complete = newest.reachedFloor && !newest.limited
                    if let floor = newest.uids.min() { box.historyFloorUID = floor }
                    else if newest.reachedFloor { box.historyFloorUID = 1 }
                }
            } else {
                box.complete = true
                box.historyFloorUID = 1
            }
        } else if let priorUIDNext {
            if let next = info.uidNext {
                // New mail starts at the previous normal-sync UIDNEXT. A search hit may have a
                // larger UID, so MAX(remote_uid) is not a safe watermark.
                if next > priorUIDNext {
                    let floor = priorUIDNext > 0 ? priorUIDNext - 1 : 0
                    let fresh = try await newestUIDs(.max, below: next, above: floor, in: box.name, validity: validity, client: syncClient)
                    try await fetchHeaders(fresh.uids, into: box, validity: validity, items: items, client: syncClient)
                }
            } else if priorUIDNext > 0 {
                let fetched = try await syncClient.fetch(from: priorUIDNext, items: items, in: box.name, validity: validity)
                try await store.upsert(fetched.compactMap(SyncedMessage.init(fetch:)), into: box.rowID)
            }
        }

        if !firstSync {
            // CHANGEDSINCE needs CONDSTORE. Yahoo reports a mod-sequence without offering it.
            let known = await syncClient.has("CONDSTORE") ? box.highestModSeq : nil
            // Runs of stored messages, so no reply can pass the server's MESSAGELIMIT.
            let configuredSize = max(policy.checkBatch, 1)
            let advertisedSize = max(await syncClient.messageLimit ?? configuredSize, 1)
            let size = max(1, min(configuredSize, advertisedSize))
            let storedCount = try await store.uidCount(box.rowID)
            let modSeqChanged: Bool
            if let known, let current = info.highestModSeq { modSeqChanged = current > known } else { modSeqChanged = false }
            // CONDSTORE tells us an expunge/flag event happened, so check cached presence at once.
            // Small folders also stay timely on servers without CONDSTORE. Large folders defer
            // this more expensive walk to the periodic full check.
            let checkRemovals = full || modSeqChanged || (known == nil && storedCount <= size * 4)
            // Keep small folders fully flag-current so a changed message is visible on the next
            // pass. Very large non-CONDSTORE folders rotate bounded batches instead of issuing a
            // full UID allocation every time. Each SQLite page is released before the next one.
            let walkAll = known != nil || full || storedCount <= size * 4
            if walkAll {
                var after: UInt32?
                while true {
                    try Task.checkCancellation()
                    let page = try await store.uidPage(box.rowID, after: after, limit: size)
                    guard !page.isEmpty else { break }
                    try await inspectStoredUIDs(page, box: box, validity: validity, known: known,
                                                current: info.highestModSeq, checkRemovals: checkRemovals)
                    guard page.count == size, let last = page.last else { break }
                    after = last
                }
            } else {
                // Large non-CONDSTORE folders get one rotating page. If the cursor reached the
                // current high-water mark, wrap to the first page so every UID is checked over
                // successive passes without retaining all rows in memory.
                var page = try await store.uidPage(box.rowID, after: flagCursor[box.rowID], limit: size)
                if page.isEmpty, flagCursor[box.rowID] != nil {
                    page = try await store.uidPage(box.rowID, limit: size)
                }
                if let last = page.last { flagCursor[box.rowID] = last }
                try await inspectStoredUIDs(page, box: box, validity: validity, known: known,
                                            current: info.highestModSeq, checkRemovals: checkRemovals)
            }
        }
        if full { box.lastFullCheck = Date() }
        box.highestModSeq = info.highestModSeq
        box.uidNext = info.uidNext
        try await store.saveSyncState(box)
        replace(box)
    }

    /// Checks one bounded run of stored UIDs. The run comes from `uidPage`, so a large mailbox
    /// never needs an in-memory catalogue just to refresh flags or detect removals.
    private func inspectStoredUIDs(_ run: [UInt32], box: NativeMailStore.Mailbox, validity: UInt32,
                                   known: UInt64?, current: UInt64?, checkRemovals: Bool) async throws {
        guard !run.isEmpty else { return }
        // A UID page can be sparse. Naming low:high would include every gap and can exceed a
        // server's MESSAGELIMIT even though the SQLite page itself is bounded.
        let range = IMAPSequenceSet(run)
        if let known, let current {
            if current > known {
                let changes = try await syncClient.fetch(uids: range, items: "(UID FLAGS)", changedSince: known,
                                                         in: box.name, validity: validity)
                try await store.updateFlags(changes.compactMap { data in data.uid.map { ($0, data.flags ?? []) } }, in: box.rowID)
            }
        } else {
            let flags = try await syncClient.fetch(uids: range, items: "(UID FLAGS)", in: box.name, validity: validity)
            try await store.updateFlags(flags.compactMap { data in data.uid.map { ($0, data.flags ?? []) } }, in: box.rowID)
        }
        let serverUsesUIDOnly = await syncClient.uidOnly
        let advertisedMessageLimit = await syncClient.messageLimit
        let limitedView = !serverUsesUIDOnly && advertisedMessageLimit != nil
        if checkRemovals, !limitedView {
            let present = try await syncClient.search("UID \(range.description)", in: box.name, validity: validity)
            try await store.remove(uids: Self.missing(run, from: present), from: box.rowID)
        }
    }

    /// One older batch of a mailbox, read when its list reaches the end of what this Mac has.
    /// Returns whether the server holds older mail still, or nil when the mailbox is not this account's.
    public func loadOlder(_ rowID: Int64) async throws -> Bool? {
        guard var box = mailboxes.first(where: { $0.rowID == rowID }) else { return nil }
        guard !box.complete, box.uidValidity != nil else { return false }
        if box.uidNext == nil || box.historyFloorUID == nil {
            try await sync(box, full: false)
            guard let refreshed = mailboxes.first(where: { $0.rowID == rowID }) else { return false }
            box = refreshed
        }
        guard !box.complete, let validity = box.uidValidity, let historyFloor = box.historyFloorUID else { return false }
        let low = historyFloor
        guard low > 1 else {
            let info = try await actionClient.select(box.name)
            guard info.uidValidity == validity else { throw MailError.uidValidityChanged(mailbox: box.name) }
            let serverUsesUIDOnly = await actionClient.uidOnly
            let advertisedMessageLimit = await actionClient.messageLimit
            let limitedView = !serverUsesUIDOnly && advertisedMessageLimit != nil
            if limitedView { throw limitedHistoryError(box.name) }
            try await markComplete(rowID)
            return false
        }
        let older = try await newestUIDs(policy.olderBatch, below: low, above: 0, in: box.name, validity: validity, client: actionClient)
        try await fetchHeaders(older.uids, into: box, validity: validity, items: await items(actionClient), client: actionClient)
        var updated = box
        if let floor = older.uids.min() { updated.historyFloorUID = floor }
        else if older.reachedFloor { updated.historyFloorUID = 1 }
        if older.reachedFloor, !older.limited { updated.complete = true }
        try await store.saveSyncState(updated)
        replace(updated)
        if older.reachedFloor, older.limited { throw limitedHistoryError(box.name) }
        return !older.reachedFloor
    }

    private func markComplete(_ rowID: Int64) async throws {
        try await store.setComplete(rowID)
        if let index = mailboxes.firstIndex(where: { $0.rowID == rowID }) { mailboxes[index].complete = true }
    }

    /// Up to `count` of the highest UIDs above `floor` and below `ceiling`, lowest first. Each UID
    /// SEARCH covers a range sized from the one before, so its reply stays inside the server's
    /// MESSAGELIMIT; a refused range is halved. `reachedFloor` is true when nothing below the
    /// lowest UID returned is left unread.
    func newestUIDs(_ count: Int, below ceiling: UInt32, above floor: UInt32, in mailbox: String,
                    validity: UInt32, client: IMAPClient) async throws -> (uids: [UInt32], reachedFloor: Bool, limited: Bool) {
        let wanted = max(count, 1)
        let limit = await client.messageLimit.map { max($0, 1) }
        let limited = !(await client.uidOnly) && limit != nil
        guard floor < UInt32.max - 1, ceiling > floor + 1 else { return ([], true, limited) }
        let first = wanted >= Int(UInt32.max / 2) ? Int(UInt32.max) : wanted * 2
        var span = UInt32(clamping: min(limit ?? first, first))
        var found: [UInt32] = []
        var top = ceiling - 1
        while true {
            try Task.checkCancellation()
            let low = top - floor > span ? top - span + 1 : floor + 1
            let set: IMAPSequenceSet
            do {
                set = try await client.search("UID \(low):\(top)", in: mailbox, validity: validity)
            } catch MailError.commandFailed(_, .no, _) where top - low >= 16 {
                // More than the server returns at once, such as Yahoo's "partial results".
                span = (top - low + 1) / 2
                continue
            }
            let hits = set.numbers.filter { $0 >= low && $0 <= top }
            found += hits.reversed()
            let reachedFloor = low == floor + 1
            if found.count >= wanted || reachedFloor {
                // Reaching the floor proves completeness only when the bounded request
                // contained every hit in that range. If more than `wanted` UIDs were found,
                // the returned page is still only the newest slice and loadOlder must continue.
                let complete = reachedFloor && found.count <= wanted
                return (Array(found.prefix(wanted).reversed()), complete, limited)
            }
            let searched = Double(top - low + 1)
            top = low - 1
            if hits.isEmpty {
                span = span > UInt32.max / 2 ? UInt32.max : span * 2
            } else {
                let density = Double(hits.count) / searched
                var next = Double(count - found.count) * 1.25 / density
                if let limit { next = min(next, Double(limit) * 0.8 / density) }
                span = UInt32(min(max(next.rounded(.up), 1), Double(UInt32.max)))
            }
        }
    }

    private func limitedHistoryError(_ mailbox: String) -> MailError {
        .notFound("The server exposes only a limited recent view of \(mailbox). Older history is not proven complete; enable UIDONLY or use the server's full-history view before loading older mail.")
    }

    /// Headers of `uids`, newest first, so the top of the list fills in before the rest. A server
    /// cuts a FETCH short past its MESSAGELIMIT, so no batch is larger.
    func fetchHeaders(_ uids: [UInt32], into box: NativeMailStore.Mailbox, validity: UInt32, items: String, client: IMAPClient) async throws {
        let size = max(1, min(max(policy.headerBatch, 1), await client.messageLimit.map { max($0, 1) } ?? .max))
        for chunk in IMAPSequenceSet(uids).chunked(maxCount: size).reversed() {
            try Task.checkCancellation()
            let fetched = try await client.fetch(uids: chunk, items: items, in: box.name, validity: validity)
            try await store.upsert(fetched.compactMap(SyncedMessage.init(fetch:)), into: box.rowID)
            await announce()
        }
    }

    /// Bodies of the newest inbox messages, one batch per step, so new mail opens at once.
    private func prefetchBodies() async throws -> Bool {
        guard policy.prefetchInbox > 0 else { return false }
        let offline = try await store.offlinePolicy(for: account.id)
        guard !offline.paused, offline.indexBodies || offline.downloadAttachments else { return false }
        for box in mailboxes where box.role == .inbox {
            guard let validity = box.uidValidity else { continue }
            let within = offline.mode == .recent ? min(policy.prefetchInbox, offline.recentMessageLimit) : policy.prefetchInbox
            guard within > 0 else { continue }
            let missing = try await store.missingBodies(in: box.rowID, within: within, limit: policy.bodyBatch, maxSize: policy.prefetchMaxSize, requireRaw: offline.downloadAttachments, requireIndex: offline.indexBodies)
            guard !missing.isEmpty else { continue }
            try await fetchBodies(missing, in: box, validity: validity, client: syncClient, storeRaw: offline.downloadAttachments, indexText: offline.indexBodies)
            return true
        }
        return false
    }

    func fetchBodies(_ rows: [(rowID: Int64, uid: UInt32)], in box: NativeMailStore.Mailbox, validity: UInt32, client: IMAPClient, storeRaw: Bool = true, indexText: Bool = true) async throws {
        var uncached: [(rowID: Int64, uid: UInt32)] = []
        for row in rows {
            if indexText, let raw = try await store.storedBody(row.rowID), let message = MIMEMessage.parse(raw) {
                try await store.saveIndexedBodyText(row.rowID, text: message.readableText)
            } else { uncached.append(row) }
        }
        let rows = uncached
        let advertised = await client.messageLimit ?? rows.count
        let size = max(1, min(rows.count, advertised))
        for chunk in IMAPSequenceSet(rows.map(\.uid)).chunked(maxCount: size) {
            let fetched = try await client.fetch(uids: chunk, items: "(UID BODY.PEEK[])", in: box.name, validity: validity)
            var rowFor: [UInt32: Int64] = [:]
            for row in rows where chunk.numbers.contains(row.uid) { rowFor[row.uid] = row.rowID }
            for data in fetched {
                guard let uid = data.uid, let rowID = rowFor[uid], let raw = data.message else { continue }
                if storeRaw { try await store.saveBody(rowID, raw: raw, indexText: indexText) }
                else if let text = MIMEMessage.parse(raw)?.readableText { try await store.saveIndexedBodyText(rowID, text: text) }
            }
        }
        await announce()
    }

    // MARK: IDLE

    private func startIdleIfNeeded() {
        guard idler == nil, mailboxes.contains(where: { $0.role == .inbox }) else { return }
        idler = Task { await self.idleLoop() }
    }

    private func idleLoop() async {
        var failures = 0
        while !Task.isCancelled {
            guard let inbox = mailboxes.first(where: { $0.role == .inbox }) else { return }
            do {
                let outcome = try await idleClient.idle(in: inbox.name, for: policy.idle)
                failures = 0
                if outcome == .changed { await signal.post(.inboxOnly) }
            } catch is CancellationError {
                return
            } catch MailError.idleUnsupported {
                try? await Task.sleep(nanoseconds: UInt64(policy.poll * 1_000_000_000))
                await signal.post(.inboxOnly)
            } catch MailError.signInFailed {
                return
            } catch {
                if Task.isCancelled { return }
                failures += 1
                try? await Task.sleep(nanoseconds: UInt64(min(300, 5 << min(failures, 6))) * 1_000_000_000)
                // Anything that arrived while the connection was down is read now.
                await signal.post(.inboxOnly)
            }
        }
    }

    // MARK: Helpers

    /// `uids` in order, in runs of at most `size`.
    static func runs(_ uids: [UInt32], size: Int) -> [[UInt32]] {
        stride(from: 0, to: uids.count, by: max(size, 1)).map { Array(uids[$0..<min($0 + max(size, 1), uids.count)]) }
    }

    /// Stored UIDs (lowest first) that the server's set no longer has, in one walk of both.
    static func missing(_ stored: [UInt32], from present: IMAPSequenceSet) -> [UInt32] {
        var gone: [UInt32] = []
        var rangeIndex = 0
        let ranges = present.ranges
        for uid in stored {
            while rangeIndex < ranges.count, ranges[rangeIndex].upperBound < uid { rangeIndex += 1 }
            if rangeIndex >= ranges.count || !ranges[rangeIndex].contains(uid) { gone.append(uid) }
        }
        return gone
    }
}
