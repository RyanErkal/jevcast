import Foundation

/// Keeps one account's mail on this Mac in step with its server. It uses three connections: one
/// for sync, one for changes you make, so they never wait behind a long sync, and one that waits
/// in IDLE for new mail. The newest mail comes first; older mail and bodies follow in small steps.
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
    /// Older UIDs still to read, per mailbox, highest first, from one SEARCH.
    private var older: [Int64: [UInt32]] = [:]
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
                // More work goes on in short steps; new mail from IDLE still comes first.
                if more { request = await signal.wait(timeout: 0.5) ?? MailSyncRequest(backfill: true) }
                else { request = await signal.wait(timeout: policy.periodic) ?? .everything }
            case .signIn:
                request = await signal.wait(timeout: 3600) ?? .everything
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
            var targets: [NativeMailStore.Mailbox] = request.all ? mailboxes : []
            if !request.all {
                if request.inbox { targets += mailboxes.filter { $0.role == .inbox } }
                targets += mailboxes.filter { request.mailboxes.contains($0.rowID) && $0.role != .inbox }
            }
            for box in targets {
                try Task.checkCancellation()
                let full = box.role == .inbox || box.lastFullCheck.map { now.timeIntervalSince($0) > policy.fullCheck } ?? true
                try await sync(box, full: full)
                await announce()
            }
            var more = try await prefetchBodies()
            if request.backfill || request.all { more = try await backfill() || more }
            if case .ready = state, !visible {} else { setState(.ready(Date())) }
            return .done(more: more)
        } catch is CancellationError {
            return .cancelled
        } catch MailError.uidValidityChanged {
            // The next pass reads the mailbox again from the start.
            listedAt = nil
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
        mailboxes = try await store.replaceMailboxes(account: account.id, with: entries)
        listedAt = Date()
        older = older.filter { entry in mailboxes.contains { $0.rowID == entry.key } }
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

    private func items() async -> String { SyncedMessage.fetchItems(gmail: await syncClient.has("X-GM-EXT-1")) }

    // MARK: One mailbox

    /// New mail, then flag changes, then removed messages. Only new mail costs a download.
    func sync(_ original: NativeMailStore.Mailbox, full: Bool) async throws {
        var box = original
        let info: IMAPClient.MailboxInfo
        do { info = try await syncClient.select(box.name) } catch MailError.commandFailed(_, .no, _) {
            // The mailbox went away or cannot be opened; the next listing decides.
            listedAt = nil
            return
        }
        if let known = box.uidValidity, known != info.uidValidity {
            box = try await store.reset(box, uidValidity: info.uidValidity)
            older[box.rowID] = nil
        }
        box.uidValidity = info.uidValidity
        let validity = info.uidValidity
        let items = await items()
        let before = try await store.extent(box.rowID)
        var firstSync = false

        if let maxUID = before.maxUID {
            if info.uidNext.map({ $0 > maxUID + 1 }) ?? true {
                let fetched = try await syncClient.fetch(from: maxUID + 1, items: items, in: box.name, validity: validity)
                try await store.upsert(fetched.compactMap(SyncedMessage.init(fetch:)), into: box.rowID)
            }
        } else if info.exists > 0 {
            firstSync = true
            let all = try await syncClient.search("ALL", in: box.name, validity: validity)
            let newest = Self.highest(all, count: box.role == .inbox ? policy.firstInbox : policy.firstOther)
            for chunk in IMAPSequenceSet(newest).chunked(maxCount: policy.headerBatch) {
                let fetched = try await syncClient.fetch(uids: chunk, items: items, in: box.name, validity: validity)
                try await store.upsert(fetched.compactMap(SyncedMessage.init(fetch:)), into: box.rowID)
                await announce()
            }
            box.complete = newest.count >= all.count
            older[box.rowID] = box.complete ? nil : Self.below(newest.min(), in: all)
        } else {
            box.complete = true
        }

        let stored = try await store.extent(box.rowID)
        if !firstSync, let low = stored.minUID, let high = stored.maxUID {
            let range = IMAPSequenceSet(ranges: [low...high])
            if let known = box.highestModSeq, let current = info.highestModSeq {
                if current > known {
                    let changes = try await syncClient.fetch(uids: range, items: "(UID FLAGS)", changedSince: known, in: box.name, validity: validity)
                    try await store.updateFlags(changes.compactMap { data in data.uid.map { ($0, data.flags ?? []) } }, in: box.rowID)
                }
            } else if full {
                let flags = try await syncClient.fetch(uids: range, items: "(UID FLAGS)", in: box.name, validity: validity)
                try await store.updateFlags(flags.compactMap { data in data.uid.map { ($0, data.flags ?? []) } }, in: box.rowID)
            }
            if full {
                let present = try await syncClient.search("UID \(low):\(high)", in: box.name, validity: validity)
                try await store.remove(uids: Self.missing(try await store.uids(box.rowID), from: present), from: box.rowID)
            }
        }
        if full { box.lastFullCheck = Date() }
        box.highestModSeq = info.highestModSeq
        box.uidNext = info.uidNext
        try await store.saveSyncState(box)
        replace(box)
    }

    /// Older messages, one batch per mailbox per step, newest of them first.
    private func backfill() async throws -> Bool {
        var more = false
        for original in mailboxes where !original.complete {
            try Task.checkCancellation()
            var box = original
            guard let validity = box.uidValidity else { continue }
            if older[box.rowID] == nil {
                let extent = try await store.extent(box.rowID)
                if let low = extent.minUID, low > 1 {
                    older[box.rowID] = try await syncClient.search("UID 1:\(low - 1)", in: box.name, validity: validity).numbers.reversed()
                } else {
                    older[box.rowID] = []
                }
            }
            let queue = older[box.rowID] ?? []
            guard !queue.isEmpty else {
                box.complete = true
                older[box.rowID] = nil
                try await store.saveSyncState(box)
                replace(box)
                continue
            }
            let batch = Array(queue.prefix(policy.backfillBatch))
            older[box.rowID] = Array(queue.dropFirst(batch.count))
            let items = await items()
            for chunk in IMAPSequenceSet(batch).chunked(maxCount: policy.headerBatch) {
                let fetched = try await syncClient.fetch(uids: chunk, items: items, in: box.name, validity: validity)
                try await store.upsert(fetched.compactMap(SyncedMessage.init(fetch:)), into: box.rowID)
            }
            await announce()
            more = true
        }
        return more
    }

    /// Bodies of the newest messages, one batch per step: the inbox first, then Sent and Archive.
    private func prefetchBodies() async throws -> Bool {
        for box in mailboxes {
            let within: Int
            switch box.role {
            case .inbox: within = policy.prefetchInbox
            case .sent, .archive: within = policy.prefetchOther
            default: within = 0
            }
            guard within > 0, let validity = box.uidValidity else { continue }
            let missing = try await store.missingBodies(in: box.rowID, within: within, limit: policy.bodyBatch, maxSize: policy.prefetchMaxSize)
            guard !missing.isEmpty else { continue }
            try await fetchBodies(missing, in: box, validity: validity, client: syncClient)
            return true
        }
        return false
    }

    func fetchBodies(_ rows: [(rowID: Int64, uid: UInt32)], in box: NativeMailStore.Mailbox, validity: UInt32, client: IMAPClient) async throws {
        let fetched = try await client.fetch(uids: IMAPSequenceSet(rows.map(\.uid)), items: "(UID BODY.PEEK[])", in: box.name, validity: validity)
        var rowFor: [UInt32: Int64] = [:]
        for row in rows { rowFor[row.uid] = row.rowID }
        for data in fetched {
            guard let uid = data.uid, let rowID = rowFor[uid], let raw = data.message else { continue }
            try await store.saveBody(rowID, raw: raw)
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

    /// The `count` highest numbers of a set, lowest first.
    static func highest(_ set: IMAPSequenceSet, count: Int) -> [UInt32] {
        var result: [UInt32] = []
        for range in set.ranges.reversed() {
            var value = range.upperBound
            while result.count < count {
                result.append(value)
                if value == range.lowerBound { break }
                value -= 1
            }
            if result.count >= count { break }
        }
        return result.reversed()
    }

    /// Numbers of `set` below `limit`, highest first.
    static func below(_ limit: UInt32?, in set: IMAPSequenceSet) -> [UInt32] {
        guard let limit else { return [] }
        return set.numbers.filter { $0 < limit }.reversed()
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
