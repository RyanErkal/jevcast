import AppKit
import Combine
import LauncherCore

/// The mail window's state. Lists come from Mail's index; changes go through Apple Mail;
/// the list updates when Mail's index changes.
@MainActor
final class MailModel: ObservableObject {
    enum Place: Hashable {
        case inbox, allMail, unread, flagged
        case mailbox(Int64)
    }
    @Published private(set) var status: MailStore.Status = .noMail
    @Published private(set) var mailboxes: [MailMailbox] = []
    @Published var place: Place = .inbox { didSet { if oldValue != place { selectedID = nil; reload(); syncPlace() } } }
    @Published var search = "" { didSet { if oldValue != search { reloadSoon() } } }
    /// The search field shows only while searching.
    @Published var searching = false
    /// Web images in HTML mail. On by default; the ⋯ menu turns them off.
    @Published var loadsImages = UserDefaults.standard.object(forKey: "mailLoadsImages") as? Bool ?? true {
        didSet { UserDefaults.standard.set(loadsImages, forKey: "mailLoadsImages") }
    }
    /// True while the mail window has the keyboard, so a message counts as read only when seen.
    /// Coming back to the window counts the message on screen.
    var windowIsKey = false { didSet { if windowIsKey != oldValue { armRead() } } }
    private var readTimer: Task<Void, Never>?
    @Published private(set) var messages: [MailSummary] = [] {
        didSet { pageTriggerID = messages.count > 30 ? messages[messages.count - 30].rowID : messages.last?.rowID }
    }
    /// The row that asks for the next page when it appears: 30 rows before the end.
    private(set) var pageTriggerID: Int64?
    /// True while an older page may exist below the list.
    @Published private(set) var hasMore = false
    /// Empty Trash or Junk: the mailbox and exactly the messages counted, waiting for your yes.
    struct EmptyRequest: Identifiable {
        let mailbox: MailMailbox
        let uids: [UInt32]
        let validity: UInt32
        var id: Int64 { mailbox.rowID }
    }
    @Published var emptyRequest: EmptyRequest?
    @Published private(set) var preparingEmpty = false

    /// True while a Jevcast account's server may hold older mail than this Mac has for the list.
    @Published private(set) var olderOnServer = false
    private var loadingOlder = false
    /// False when Apple Mail is not running, so new mail is not reaching its index.
    @Published private(set) var mailRunning = true
    /// The message on screen counts as read however it got there: from the list, the keyboard, or
    /// the model's own selection after a reload or a delete. `select(_:byUser:)` with false marks
    /// the model's own selections, which wait for a search to settle.
    @Published var selectedID: Int64? {
        didSet {
            guard oldValue != selectedID else { return }
            keptUnread = nil
            loadSelected()
            armRead(searchPick: selectingQuietly && !search.isEmpty)
        }
    }
    private var selectingQuietly = false
    /// The message you marked unread while it is on screen. It stays unread until you move away.
    private var keptUnread: Int64?
    /// Read changes made here, until Mail's index shows them. Mail writes the index a moment after
    /// the change, so a refresh in between must not mark the row unread again.
    private var readChanges: [Int64: (read: Bool, at: Date)] = [:]
    /// Accounts changed while the window is open, so closing asks Mail to send the changes to the server.
    private var changedAccounts: Set<String> = []
    private let setReadAction: (Bool, MailSummary, MailMailbox, MailMailbox?) async throws -> Void
    /// A message to select once the list that holds it loads, such as one picked in the launcher.
    private var pending: MailSummary?
    private var pendingOpen: Int64?
    private var openWork: Task<Void, Never>?
    @Published private(set) var detail: MIMEMessage?
    @Published private(set) var detailMissing = false
    @Published var banner: String?
    @Published private(set) var summary: String?

    // MARK: Compose state. MailModel+Compose.swift changes these; views only read them.

    /// The open reply, forward, or new message. Changing what it says clears the footer note and
    /// the first Escape of a discard.
    @Published var draft: Draft? {
        didSet {
            persistComposition()
            guard oldValue?.id != draft?.id || oldValue?.fields != draft?.fields else { return }
            discardArmed = false
            if composeNote != nil { composeNote = nil }
        }
    }
    /// A note in the composer's footer, such as why Send did nothing or that Escape again discards.
    @Published var composeNote: String?
    /// Set by the first Escape on a draft with text. The second discards it.
    var discardArmed = false
    /// Counts refused new drafts, so a view that hid the open draft shows it again.
    @Published var draftNudge = 0
    /// A sent draft during its undo time. Undo brings it back; after the time it goes to Mail.
    @Published var pendingSend: Draft?
    /// Names the waiting send. A draft sent again after Undo gets a new one.
    var pendingTicket: UUID?
    /// When the waiting draft goes to Mail, for the banner's countdown.
    @Published var sendsAt: Date?
    /// Sends not finished yet: waiting for Undo or on their way to Mail.
    @Published var sendsInFlight = 0
    /// Drafts that did not go, oldest first. The banner offers Show.
    @Published var unsent: [Unsent] = [] { didSet { persistComposition() } }
    @Published var deliveries: [MailDelivery] = [] { didSet { persistComposition() } }
    @Published var showsOutbox = false
    @Published var senders: [MailSendingIdentity] = []
    let draftStore: MailDraftStore?
    @Published var persistenceProblem: String?
    var persistenceWork: Task<Void, Never>?
    /// Tickets of waiting sends that Undo took back.
    var undoneSends: Set<UUID> = []
    /// The latest send. Each send waits for the one before, so waiting for this waits for all.
    var sendTask: Task<Void, Never>?
    /// The undo time of the waiting send. Cancelling it sends at once.
    var undoTimer: Task<Void, Never>?
    let sendDraft: (Draft, MailMailbox?) async throws -> Void
    /// Seconds a sent message waits, so Undo can stop it.
    let undoDelay: TimeInterval
    /// Called when a send fails, with a note for the user. The app shows it when no mail view is on screen.
    var onSendFailure: ((String) -> Void)?
    @Published var aiWritingBusy = false

    let aiWriting: (AIWritingRequest) async throws -> AIWritingReply
    private let aiWritingAllowed: () -> Bool
    private var root: String? { if case .ready(let root) = status { return root }; return nil }
    private var fingerprint = ""
    private var poll: Task<Void, Never>?
    private var searchWork: Task<Void, Never>?
    private var loadWork: Task<Void, Never>?
    /// The newest and oldest cursors for the current list.
    private var top: MailStore.Cursor?
    @Published private(set) var bottom: MailStore.Cursor?
    private var loadingMore = false
    var isLoading: Bool { reloading || loadingMore || refreshing || bodySearch == .running }
    /// The body phase of a search: off without a search, `more` when rows remain unread.
    enum BodySearch: Equatable { case off, running, more, done }
    @Published private(set) var bodySearch = BodySearch.off
    /// Where the body phase goes on: the oldest row it read.
    private var bodyCursor: MailStore.Cursor?
    private var reloading = false
    private var refreshing = false
    private let statusProvider: @Sendable () -> MailStore.Status
    private var statusWork: Task<Void, Never>?
    private var indexIdentity: MailStore.FileIdentity?
    /// Changes with every full reload, so late results for an older list are dropped.
    private var generation = 0
    /// Stops the SQL of a list that a newer reload replaced.
    private var listStop = StopFlag()
    /// The selected HTML body with its inline images already in place, prepared off the main thread.
    @Published private(set) var detailHTML: String?
    /// Parsed and prepared bodies of recent messages, most recently used last, so moving back
    /// and forth shows them at once.
    private struct Body { let message: MIMEMessage; let html: String? }
    private var bodies: [Int64: Body] = [:]
    private var bodyOrder: [Int64] = []
    private static let bodyLimit = 24
    /// Messages removed here whose change Mail has not written to its index yet. A refresh in the
    /// meantime must not bring them back.
    private var removing: [Int64: Date] = [:]
    /// Mail actions run one after another, so quick deletes never race each other.
    private var actionChain: Task<Void, Never>?

    init(aiWriting: @escaping (AIWritingRequest) async throws -> AIWritingReply, aiWritingAllowed: @escaping () -> Bool, statusProvider: @escaping @Sendable () -> MailStore.Status = { MailStore.status() },
         setRead: @escaping (Bool, MailSummary, MailMailbox, MailMailbox?) async throws -> Void = { try await MailActions.setRead($0, $1, in: $2, fallback: $3) },
         sendDraft: @escaping (Draft, MailMailbox?) async throws -> Void = { try await MailModel.deliver($0, $1) }, undoDelay: TimeInterval = 5,
         draftStore: MailDraftStore? = MailDraftStore.standard) {
        self.draftStore = draftStore
        self.statusProvider = statusProvider
        self.setReadAction = setRead
        self.sendDraft = sendDraft
        self.undoDelay = undoDelay
        self.aiWriting = aiWriting; self.aiWritingAllowed = aiWritingAllowed
        if let draftStore {
            do {
                let stored = try draftStore.load()
                draft = stored.active; unsent = stored.unsent; deliveries = stored.deliveries
                try draftStore.save(stored)
            } catch {
                persistenceProblem = "Saved drafts could not be read: " + error.localizedDescription
                banner = persistenceProblem
            }
        }
        // Settings › Mail writes the same default; follow it while this window exists.
        defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let stored = UserDefaults.standard.object(forKey: "mailLoadsImages") as? Bool ?? true
                if let self, self.loadsImages != stored { self.loadsImages = stored }
            }
        // Jevcast's own store says when it changes, so new mail and changes show without waiting for a poll.
        nativeObserver = NotificationCenter.default.publisher(for: NativeMailCenter.changed)
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.poll != nil else { return }
                self.loadSenders()
                // A change of mail source, or a first account, needs the store found again.
                if NativeMailCenter.isActive, let root = self.root, NativeMailCenter.isNativeRoot(root) { self.refresh() } else { self.refreshStatus() }
            }
    }
    private var defaultsObserver: AnyCancellable?
    private var nativeObserver: AnyCancellable?

    var selected: MailSummary? { messages.first { $0.rowID == selectedID } }
    func mailbox(_ id: Int64) -> MailMailbox? { mailboxes.first { $0.rowID == id } }
    /// The list's title, such as "Inbox" or a mailbox's name.
    var placeTitle: String {
        switch place {
        case .inbox: return "Inbox"
        case .allMail: return "All Mail"
        case .unread: return "Unread"
        case .flagged: return "Flagged"
        case .mailbox(let id): return mailbox(id)?.name ?? "Mailbox"
        }
    }
    var inboxes: [MailMailbox] { mailboxes.filter { $0.role == .inbox } }
    var accounts: [String] { Array(Set(mailboxes.map(\.accountID))).sorted { accountTitle($0).localizedStandardCompare(accountTitle($1)) == .orderedAscending } }

    /// The account's address for headings, such as in the mailbox picker; its ID when unknown.
    func accountTitle(_ account: String) -> String {
        senders.first { $0.accountID == account }?.address ?? account
    }
    var unreadInInbox: Int { inboxes.map(\.unread).reduce(0, +) }
    var canUseAIWriting: Bool { aiWritingAllowed() }

    // MARK: Loading

    /// Checks access, loads mailboxes, and starts watching Mail's index while the window is open.
    func start() {
        loadSenders()
        refreshStatus()
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                // Quick index checks at first, while Mail starts and fetches, then every 2 seconds.
                try? await Task.sleep(nanoseconds: ticks < 10 ? 1_000_000_000 : 2_000_000_000)
                guard !Task.isCancelled else { return }
                ticks += 1
                guard let self, let root = self.root else { continue }
                self.updateMailRunning()
                let current = await Task.detached { MailStore.fingerprint(root: root) }.value
                if current != self.fingerprint, self.refresh() { self.fingerprint = current }
                // Mail fetches on its own timer, which can be minutes. Ask again soon after it
                // starts, then every 30 seconds while the inbox is open.
                if ticks == 5 || ticks % 15 == 0 { self.checkForNewMail() }
            }
        }
    }

    /// Closing never quits Apple Mail. Its own quit settings can permanently purge Trash.
    func stop() {
        poll?.cancel(); poll = nil; readTimer?.cancel()
        statusWork?.cancel(); statusWork = nil
        openWork?.cancel(); openWork = nil; pendingOpen = nil
        let accounts = Array(changedAccounts)
        changedAccounts = []
        let pending = actionChain
        Task {
            await pending?.value
            if !accounts.isEmpty { try? await MailActions.synchronize(accounts: accounts) }
        }
        do { try saveComposition() } catch { banner = error.localizedDescription }
    }

    /// Starts Apple Mail hidden, if needed, and asks it to fetch new mail. New mail reaches the
    /// index only while Mail runs.
    private func fetchNewMail() {
        // Jevcast's own accounts sync by themselves; Apple Mail is never started for them.
        if NativeMailCenter.isActive { checkForNewMail(); return }
        let wasRunning = AppleScript.isRunning(MailActions.bundleID)
        if !wasRunning { MailActions.openedByUser = false }
        checkForNewMail()
    }
    /// One "check for new mail" at a time. A failure shows once, not on every repeat.
    private var checking = false
    private var reportedCheckFailure = false
    private func checkForNewMail() {
        guard !checking else { return }
        checking = true
        Task { @MainActor [weak self] in
            do {
                try await MailActions.checkForNewMail()
                self?.reportedCheckFailure = false
            } catch {
                if self?.reportedCheckFailure == false { self?.banner = "Could not check for new mail: " + error.localizedDescription }
                self?.reportedCheckFailure = true
            }
            self?.checking = false
        }
    }

    private func updateMailRunning() {
        let running = NativeMailCenter.isActive || AppleScript.isRunning(MailActions.bundleID)
        if mailRunning != running { mailRunning = running }
    }

    /// Starts Apple Mail in the background, without taking focus, so new mail arrives.
    func openMailInBackground() {
        MailActions.openedByUser = true
        Task { @MainActor [weak self] in
            do { try await MailActions.ensureRunning(); self?.updateMailRunning(); self?.checkForNewMail() }
            catch { self?.banner = error.localizedDescription }
        }
    }

    func refreshStatus() {
        statusWork?.cancel()
        let provider = statusProvider
        statusWork = Task { @MainActor [weak self] in
            let status = await Task.detached(priority: .userInitiated) { provider() }.value
            guard !Task.isCancelled, let self else { return }
            self.statusWork = nil
            if self.status != status {
                self.listStop.stop(); self.generation += 1
                self.bodies.removeAll(); self.bodyOrder.removeAll()
                self.select(nil, byUser: false)
            }
            self.status = status
            guard let root = self.root else {
                self.mailboxes = []; self.messages = []; self.hasMore = false
                self.pendingOpen = nil
                self.loadingMore = false; self.refreshing = false; self.reloading = false
                return
            }
            self.fingerprint = MailStore.fingerprint(root: root)
            self.reload()
            if let rowID = self.pendingOpen { self.pendingOpen = nil; self.open(rowID) }
            if self.poll != nil { self.fetchNewMail() }
        }
    }

    private func reloadSoon() {
        searchWork?.cancel()
        // A newer search stops the older one's query at once, then waits for typing to pause.
        listStop.stop()
        generation += 1
        loadingMore = false; refreshing = false; reloading = false
        bodySearch = .off; bodyCursor = nil
        searchWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// Reads the first page of the list again. The selection stays when its message is still listed.
    func reload(keepSelection: Bool = false) {
        guard let root else { return }
        let place = self.place, search = self.search
        let keptIDs = keepSelection ? messages.map(\.rowID) : []
        loadWork?.cancel()
        listStop.stop()
        let stop = StopFlag()
        listStop = stop
        generation += 1
        loadingMore = false; refreshing = false; reloading = true
        bodySearch = .off; bodyCursor = nil
        olderOnServer = search.isEmpty && NativeMailCenter.activeEngine != nil
        let generation = self.generation
        updateMailRunning()
        loadWork = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (MailStore.Page, [MailMailbox], MailStore.FileIdentity?, [Int64: MailStore.RowState])? in
                let identity = MailStore.FileIdentity(path: MailStore.indexPath(root))
                guard let boxes = try? MailStore.mailboxes(root: root) else { return nil }
                guard let page = try? MailStore.page(root: root, Self.query(place, search, boxes), stop: stop.check) else { return nil }
                guard let states = try? MailStore.states(root: root, rowIDs: keptIDs, stop: stop.check) else { return nil }
                return (page, boxes, identity, states)
            }.value
            guard !Task.isCancelled, !stop.isStopped, let self, self.generation == generation else { return }
            self.reloading = false
            let previous = self.selectedID
            guard let (page, boxes, identity, states) = result else {
                self.fingerprint = ""
                self.banner = "Mail's index could not be read. Try again in a moment."; return
            }
            if self.indexIdentity != identity {
                self.bodies.removeAll(); self.bodyOrder.removeAll()
                self.detail = nil; self.detailHTML = nil; self.detailMissing = false; self.loadingID = nil
            }
            self.indexIdentity = identity
            // Removals older than two minutes are Mail's business again.
            self.removing = self.removing.filter { Date().timeIntervalSince($0.value) < 120 }
            self.mailboxes = boxes
            self.confirmReads(page.messages.map { ($0.rowID, $0.read) } + states.map { ($0.key, $0.value.read) })
            let messages = page.messages.filter { self.removing[$0.rowID] == nil }
            self.top = page.first; self.bottom = page.last; self.hasMore = page.hasMore
            // A selected message on a later page stays listed, in date order, so the selection holds.
            var merged = messages
            if keepSelection, let previous, !merged.contains(where: { $0.rowID == previous }),
               let kept = Self.refreshed(self.messages, states: states, requested: Set(keptIDs), query: Self.query(place, search, boxes), selectedID: previous)
                    .first(where: { $0.rowID == previous }), let last = page.last,
               Self.isNewer(kept, than: last) == false, page.hasMore {
                merged.append(kept)
            }
            self.install(Self.merge([], merged, query: Self.query(place, search, boxes)))
            // Subject and sender matches show now; body matches follow in a short, bounded step.
            if !search.isEmpty { self.searchBodies(budget: 0.15) }
            if let pending = self.pending {
                self.pending = nil
                if !self.messages.contains(where: { $0.rowID == pending.rowID }) {
                    self.messages = Self.merge(self.messages, [pending], query: Self.query(place, search, boxes))
                }
                self.select(pending.rowID, byUser: true)
                return
            }
            if keepSelection, let previous, self.messages.contains(where: { $0.rowID == previous }) { return }
            // A message that left the list is not replaced by one that would be marked read.
            if self.selectedID == nil || !self.messages.contains(where: { $0.rowID == self.selectedID }) { self.select(self.messages.first?.rowID, byUser: false) }
        }
    }

    /// True when `message` sorts above `cursor` in the newest-first order.
    nonisolated static func isNewer(_ message: MailSummary, than cursor: MailStore.Cursor) -> Bool {
        let date = message.date.timeIntervalSince1970
        return date > cursor.date || (date == cursor.date && message.rowID > cursor.rowID)
    }

    /// Reads the next older page and adds it below the list. Called as the list nears its end.
    func loadNextPage() {
        guard let root, hasMore, !loadingMore, !reloading, !listStop.isStopped, let bottom else { return }
        loadingMore = true
        var query = Self.query(place, search, mailboxes)
        query.before = bottom
        let stop = listStop, generation = self.generation
        Task { @MainActor [weak self] in
            let page = await Task.detached(priority: .userInitiated) { try? MailStore.page(root: root, query, stop: stop.check) }.value
            guard let self, !stop.isStopped, self.generation == generation else { return }
            self.loadingMore = false
            guard let page else { return }
            self.bottom = page.last ?? self.bottom
            self.hasMore = page.hasMore
            let oldIDs = Set(self.messages.map(\.rowID))
            let added = page.messages.filter { self.removing[$0.rowID] == nil }
            self.install(Self.merge(self.messages, added, query: query))
            // A page can contain only rows already pinned by a launcher selection or reload.
            if Set(self.messages.map(\.rowID)) == oldIDs, page.hasMore {
                self.loadNextPage()
            }
        }
    }

    /// Selects the newest message of the list, as the launcher panel opens on it.
    func showNewest() {
        if selectedID != nil { select(nil, byUser: false) }
        reload()
    }

    /// A Jevcast account reads a folder when it opens; until then the folder costs nothing.
    private func syncPlace() {
        guard case .mailbox(let id) = place, let engine = NativeMailCenter.activeEngine else { return }
        Task { await engine.sync(MailSyncRequest(mailboxes: [id])) }
    }

    /// Reads older mail from a Jevcast account's server once the list shows all this Mac has.
    func loadOlder() async {
        guard olderOnServer, !loadingOlder, !hasMore, search.isEmpty, let engine = NativeMailCenter.activeEngine else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let ids = Self.query(place, search, mailboxes).mailboxes, generation = self.generation
        var more = false
        do {
            for id in ids { more = try await engine.loadOlder(id) || more }
        } catch {
            guard self.generation == generation else { return }
            olderOnServer = false
            banner = "Older mail could not be read: " + error.localizedDescription
            return
        }
        guard self.generation == generation else { return }
        olderOnServer = more
        refresh()
    }

    /// Reads older rows for body matches, for about `budget` seconds or 200 matches.
    func searchBodies(budget: TimeInterval = 2) {
        guard let root, !search.isEmpty, !refreshing, bodySearch != .running, bodySearch != .done, !listStop.isStopped else { return }
        let query = Self.query(place, search, mailboxes), cursor = bodyCursor, stop = listStop, generation = self.generation
        bodySearch = .running
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try? MailStore.searchBodies(root: root, query, from: cursor, budget: budget, stop: stop.check)
            }.value
            guard let self, !stop.isStopped, self.generation == generation else { return }
            guard let result else { self.bodySearch = .more; return }
            self.bodyCursor = result.cursor
            self.bodySearch = result.done ? .done : .more
            let added = result.messages.filter { self.removing[$0.rowID] == nil }
            if !added.isEmpty { self.install(Self.merge(self.messages, added, query: query)) }
        }
    }

    /// Rechecks the loaded date range, including older rows that gained a mailbox label.
    @discardableResult
    func refresh() -> Bool {
        guard !reloading, !refreshing, bodySearch != .running, !listStop.isStopped else { return false }
        guard let root, let top, !messages.isEmpty else { reload(keepSelection: true); return true }
        refreshing = true
        let place = self.place, search = self.search, generation = self.generation
        let ids = messages.map(\.rowID), stop = listStop
        let identity = indexIdentity
        // Labels can change without changing date_received. Include the bottom date's ties;
        // once the list is exhausted, also check older rows that newly entered this mailbox.
        let floor = hasMore ? bottom.map { MailStore.Cursor(date: $0.date, rowID: .min) } ?? top : nil
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([MailSummary], MailStore.Cursor?, [Int64: MailStore.RowState], [MailMailbox])? in
                do {
                    guard MailStore.FileIdentity(path: MailStore.indexPath(root)) == identity else { return nil }
                    let boxes = try MailStore.mailboxes(root: root)
                    var query = Self.query(place, search, boxes)
                    query.after = floor
                    var newer: [MailSummary] = []
                    var first: MailStore.Cursor?
                    while true {
                        let page = try MailStore.page(root: root, query, stop: stop.check)
                        if first == nil { first = page.first }
                        newer += page.messages
                        guard page.hasMore, let last = page.last else { break }
                        query.before = last
                    }
                    let states = try MailStore.states(root: root, rowIDs: ids, stop: stop.check)
                    return (newer, first, states, boxes)
                } catch { return nil }
            }.value
            guard let self, !stop.isStopped, self.generation == generation else { return }
            self.refreshing = false
            guard let (newer, first, states, boxes) = result else {
                if MailStore.FileIdentity(path: MailStore.indexPath(root)) != identity { self.reload(); return }
                self.fingerprint = "" // Retry at the next poll after a transient read failure.
                return
            }
            self.mailboxes = boxes
            self.removing = self.removing.filter { Date().timeIntervalSince($0.value) < 120 }
            self.confirmReads(states.map { ($0.key, $0.value.read) } + newer.map { ($0.rowID, $0.read) })
            let query = Self.query(place, search, boxes)
            let kept = Self.refreshed(self.messages, states: states, requested: Set(ids), query: query, selectedID: self.selectedID)
            let added = newer.filter { self.removing[$0.rowID] == nil }
            if let first { self.top = first }
            self.install(Self.merge(kept, added, query: query))
            if !search.isEmpty {
                // A newly labelled row can match only its body, including behind the old body cursor.
                self.bodyCursor = nil; self.bodySearch = .off
                self.searchBodies(budget: 0.15)
            }
        }
        return true
    }

    nonisolated static func refreshed(_ messages: [MailSummary], states: [Int64: MailStore.RowState], requested: Set<Int64>,
                                      query: MailStore.Query, selectedID: Int64?) -> [MailSummary] {
        let allowed = Set(query.mailboxes)
        return messages.compactMap { original in
            // A page loaded during this refresh was not part of the state query.
            guard requested.contains(original.rowID) else { return original }
            guard let state = states[original.rowID] else { return nil }
            var message = original
            message.mailbox = state.mailbox; message.read = state.read; message.flagged = state.flagged; message.labels = state.labels
            let fits = !allowed.isDisjoint(with: message.mailboxes) && (!query.unreadOnly || !state.read) && (!query.flaggedOnly || state.flagged)
            return fits || message.rowID == selectedID ? message : nil
        }
    }

    nonisolated static func merge(_ existing: [MailSummary], _ incoming: [MailSummary], query: MailStore.Query) -> [MailSummary] {
        var rows: [Int64: MailSummary] = [:]
        for message in existing + incoming { rows[message.rowID] = message }
        var sorted = rows.values.sorted { isNewer($0, than: .init($1)) }
        if query.dedupe {
            var chosen: [String: MailSummary] = [:]
            for message in sorted {
                if let old = chosen[message.messageKey] {
                    if !query.preferred.isDisjoint(with: message.mailboxes), query.preferred.isDisjoint(with: old.mailboxes) { chosen[message.messageKey] = message }
                } else { chosen[message.messageKey] = message }
            }
            sorted = chosen.values.sorted { isNewer($0, than: .init($1)) }
        }
        return sorted
    }

    private func install(_ fresh: [MailSummary]) {
        let old = selected
        let rows = withReadChanges(fresh)
        if messages != rows { messages = rows }
        if let selectedID, let current = rows.first(where: { $0.rowID == selectedID }) {
            if old?.mailbox != current.mailbox || (detail == nil && !detailMissing && loadingID != selectedID) { loadSelected() }
            return
        }
        let replacement = old.flatMap { old in rows.first { $0.messageKey == old.messageKey } }
        select(replacement?.rowID ?? rows.first?.rowID, byUser: false)
    }

    /// Rows with a read change Mail's index does not show yet keep that change, for up to a minute.
    private func withReadChanges(_ rows: [MailSummary]) -> [MailSummary] {
        readChanges = readChanges.filter { Date().timeIntervalSince($0.value.at) < 60 }
        guard !readChanges.isEmpty else { return rows }
        return rows.map { row in
            guard let change = readChanges[row.rowID], change.read != row.read else { return row }
            var row = row
            row.read = change.read
            return row
        }
    }

    /// Drops read changes that rows fresh from Mail's index now show. After that the index decides,
    /// so a change made on another device shows here too.
    private func confirmReads(_ fresh: [(Int64, Bool)]) {
        guard !readChanges.isEmpty else { return }
        for (id, read) in fresh where readChanges[id]?.read == read { readChanges[id] = nil }
    }

    nonisolated static func query(_ place: Place, _ search: String, _ boxes: [MailMailbox]) -> MailStore.Query {
        let inboxes = boxes.filter { $0.role == .inbox }.map(\.rowID)
        let all = boxes.filter(\.inAllMail).map(\.rowID)
        switch place {
        case .inbox: return .init(mailboxes: inboxes, text: search)
        case .allMail: return .init(mailboxes: all, text: search, dedupe: true, preferred: Set(inboxes))
        case .unread: return .init(mailboxes: inboxes, text: search, unreadOnly: true)
        case .flagged: return .init(mailboxes: all, text: search, flaggedOnly: true, dedupe: true, preferred: Set(inboxes))
        case .mailbox(let id): return .init(mailboxes: [id], text: search)
        }
    }

    func select(_ rowID: Int64?, byUser: Bool) {
        let unchanged = rowID == selectedID
        selectingQuietly = !byUser
        selectedID = rowID
        selectingQuietly = false
        guard unchanged else { return }
        // The same row again, such as a message the list just inserted, still needs its body.
        if detail == nil, !detailMissing { loadSelected() }
        // Picking the message on screen again, such as in the launcher, opens it.
        if byUser { keptUnread = nil; armRead() }
    }

    /// Queues a launcher selection. The lookup runs off the main thread, including when access
    /// is still being checked on the first opening of the mail window.
    @discardableResult
    func open(_ rowID: Int64) -> Bool {
        if statusWork != nil { pendingOpen = rowID; return true }
        guard let root else { return false }
        openWork?.cancel()
        openWork = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                try? MailStore.messages(root: root, .init(mailboxes: [], rowIDs: [rowID])).first
            }.value
            guard !Task.isCancelled, let self, self.root == root else { return }
            guard let found else { self.banner = "This message is no longer in Mail's index."; return }
            self.pending = found
            // A Gmail row lives in All Mail; it opens in its Inbox when it has that label.
            let inbox = found.labels.first { id in self.mailboxes.contains { $0.rowID == id && $0.role == .inbox } }
            let target = Place.mailbox(inbox ?? found.mailbox)
            if self.place == target { self.reload() } else { self.place = target }
        }
        return true
    }

    private var loadingID: Int64?

    /// Shows the selected message's body. Loading it again, such as after a refresh, leaves its
    /// read timer alone.
    private func loadSelected() {
        summary = nil
        guard let root, let message = selected, let box = mailbox(message.mailbox) else {
            loadingID = nil
            detail = nil; detailHTML = nil; detailMissing = false; return
        }
        let rowID = message.rowID
        let identity = indexIdentity
        loadingID = rowID
        if let cached = bodies[rowID] {
            remember(cached, for: rowID)
            detail = cached.message; detailHTML = cached.html; detailMissing = false
            captureSource(rowID)
            prefetchNeighbours(of: rowID, root: root)
            return
        }
        detail = nil; detailHTML = nil; detailMissing = false
        Task { @MainActor [weak self] in
            var loaded = await Task.detached(priority: .userInitiated) { Self.loadBody(root: root, box: box, rowID: rowID) }.value
            // A Jevcast account downloads a body the first time it is shown.
            if loaded == nil, let engine = NativeMailCenter.activeEngine, (try? await engine.fetchBody(rowID)) == true {
                loaded = await Task.detached(priority: .userInitiated) { Self.loadBody(root: root, box: box, rowID: rowID) }.value
            }
            guard let self, self.root == root, self.indexIdentity == identity else { return }
            if let loaded { self.remember(loaded, for: rowID) }
            guard self.selectedID == rowID, self.loadingID == rowID else { return }
            self.detail = loaded?.message
            self.detailHTML = loaded?.html
            self.detailMissing = loaded == nil
            self.captureSource(rowID)
            self.prefetchNeighbours(of: rowID, root: root)
        }
    }

    /// The message on screen, in the window you are using, counts as read after the time set in
    /// Settings › Mail. With a delay, moving past it quickly with ↓ leaves it unread.
    /// `searchPick`: the model picked the first match of a search, which changes as you type.
    private func armRead(searchPick: Bool = false) {
        readTimer?.cancel(); readTimer = nil
        let delay = MailReading.markRead.rawValue
        guard delay >= 0, windowIsKey, let message = selected, !message.read, message.rowID != keptUnread else { return }
        let wait = searchPick ? max(delay, 1.5) : delay
        readTimer = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, let self, self.windowIsKey, let current = self.selected, current.rowID == message.rowID,
                  !current.read, current.rowID != self.keptUnread else { return }
            self.setRead(true, current)
        }
    }

    /// Changes read status through Mail. The row keeps the change until Mail's index shows it.
    private func setRead(_ read: Bool, _ message: MailSummary) {
        guard let box = actionBox(message) else { return }
        let own = mailbox(message.mailbox).flatMap { $0.rowID == box.rowID ? nil : $0 }
        readChanges[message.rowID] = (read, Date())
        let action = setReadAction
        perform(read ? "mark read" : "mark unread") { try await action(read, message, box, own) } update: { $0.read = read }
    }

    /// Parses the message and puts its inline images into the HTML, off the main thread.
    nonisolated private static func loadBody(root: String, box: MailMailbox, rowID: Int64) -> Body? {
        guard let message = MailStore.message(root: root, mailbox: box, rowID: rowID) else { return nil }
        return Body(message: message, html: message.html.map { MailHTMLView.inlining($0, images: message.inlineImages) })
    }

    private func remember(_ body: Body, for rowID: Int64) {
        bodyOrder.removeAll { $0 == rowID }
        bodyOrder.append(rowID)
        bodies[rowID] = body
        while bodyOrder.count > Self.bodyLimit { bodies.removeValue(forKey: bodyOrder.removeFirst()) }
    }

    /// Reads the messages above and below in the background, so the next one opens at once.
    private func prefetchNeighbours(of rowID: Int64, root: String) {
        guard let index = messages.firstIndex(where: { $0.rowID == rowID }) else { return }
        let wanted = [index + 1, index + 2, index - 1].filter(messages.indices.contains).map { messages[$0] }
            .filter { bodies[$0.rowID] == nil }
            .compactMap { message in mailbox(message.mailbox).map { (message.rowID, $0) } }
        guard !wanted.isEmpty else { return }
        let identity = indexIdentity
        Task { @MainActor [weak self] in
            for (id, box) in wanted {
                if let loaded = await Task.detached(priority: .utility, operation: { Self.loadBody(root: root, box: box, rowID: id) }).value {
                    guard let self, self.root == root, self.indexIdentity == identity else { return }
                    self.remember(loaded, for: id)
                }
            }
        }
    }

    // MARK: Actions

    /// Runs a Mail action. `update` changes the row at once; the index confirms it later.
    private func perform(_ name: String, removes: Bool = false, _ action: @escaping () async throws -> Void, update: ((inout MailSummary) -> Void)? = nil) {
        guard let message = selected else { return }
        if let account = mailbox(message.mailbox)?.accountID { changedAccounts.insert(account) }
        let index = messages.firstIndex { $0.rowID == message.rowID }
        if removes, let index {
            removing[message.rowID] = Date()
            messages.remove(at: index)
            // The next message shows and counts as read, as in Mail.
            select(messages.indices.contains(index) ? messages[index].rowID : messages.last?.rowID, byUser: false)
        } else if let index, let update { update(&messages[index]) }
        let backend = MailBackend.current
        let previous = actionChain
        actionChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                guard backend == MailBackend.current else { throw LauncherError("The mail source changed. Nothing was changed.") }
                try await action()
            }
            catch {
                // After a failed change the index decides the row again.
                self?.removing.removeValue(forKey: message.rowID)
                self?.readChanges.removeValue(forKey: message.rowID)
                self?.banner = "Could not \(name): \(error.localizedDescription)"
                self?.reload(keepSelection: true)
            }
        }
    }

    /// The mailbox Mail's scripts address for `message`. Bodies still load from the row's own mailbox.
    func actionBox(_ message: MailSummary) -> MailMailbox? {
        var viewing: Int64?
        if case .mailbox(let id) = place { viewing = id }
        return MailMailbox.actionTarget(for: message, viewing: viewing, in: mailboxes)
    }

    func archive() {
        guard let message = selected, let box = actionBox(message) else { return }
        guard let archive = MailMailbox.archive(for: box.accountID, in: mailboxes), archive.rowID != box.rowID else {
            banner = "This account has no Archive mailbox."; return
        }
        perform("archive", removes: true) { try await MailActions.move(message, from: box, to: archive) }
    }
    /// Deletes a message from the list, such as the one under the pointer, not only the selected one.
    func delete(_ rowID: Int64) {
        if selectedID != rowID { select(rowID, byUser: false) }
        delete()
    }
    /// Delete moves a message to Trash. In the Trash of a Jevcast account it removes the message for good.
    func delete() {
        guard let message = selected, let box = actionBox(message) else { return }
        let permanently = box.role == .trash && NativeMailCenter.isActive
        perform(permanently ? "delete permanently" : "delete", removes: true) { try await MailActions.delete(message, in: box, permanently: permanently) }
    }
    /// Deletes every message in the list from the selected message's sender: for clearing out junk.
    func deleteAllFromSender() {
        if let message = selected, actionBox(message)?.role == .trash {
            banner = "In \(actionBox(message)?.name ?? "Trash"), delete messages one at a time, or use Empty."
            return
        }
        guard let sender = selected?.senderAddress, !sender.isEmpty else { return }
        let targets = messages.filter { $0.senderAddress.caseInsensitiveCompare(sender) == .orderedSame }
        for message in targets { delete(message.rowID) }
        banner = "Deleting \(targets.count) message" + (targets.count == 1 ? "" : "s") + " from \(sender)."
    }
    var selectedSender: String? { selected?.senderAddress }

    /// True when the selected message is in its account's Junk mailbox.
    var selectedIsJunk: Bool { selected.flatMap(actionBox)?.role == .junk }

    /// Moves the selected message into its account's one Junk mailbox, or from Junk to its Inbox.
    func setJunk(_ junk: Bool) {
        guard let message = selected, let box = actionBox(message) else { return }
        let targets = mailboxes.filter { $0.accountID == box.accountID && $0.role == (junk ? .junk : .inbox) }
        guard targets.count == 1, let target = targets.first, target.rowID != box.rowID else {
            banner = junk ? "This account has no single Junk mailbox." : "This account has no single Inbox."; return
        }
        perform(junk ? "mark as junk" : "move to Inbox", removes: true) { try await MailActions.move(message, from: box, to: target) }
    }

    /// The Trash or Junk mailbox on screen, when Empty can clear it: Jevcast accounts only.
    var emptiableMailbox: MailMailbox? {
        guard NativeMailCenter.isActive, case .mailbox(let id) = place, let box = mailbox(id), box.role == .trash || box.role == .junk else { return nil }
        return box
    }

    /// Counts what Empty would remove, on the server, then asks. Only that list is removed.
    func prepareEmpty() {
        guard let box = emptiableMailbox, let engine = NativeMailCenter.activeEngine, !preparingEmpty else { return }
        preparingEmpty = true
        Task { @MainActor [weak self] in
            defer { self?.preparingEmpty = false }
            do {
                let found = try await engine.contents(of: box.rowID)
                guard let self else { return }
                if found.uids.isEmpty { self.banner = "\(box.name) is already empty."; return }
                self.emptyRequest = EmptyRequest(mailbox: box, uids: found.uids, validity: found.validity)
            } catch { self?.banner = "\(box.name) could not be read: " + error.localizedDescription }
        }
    }

    func confirmEmpty() {
        guard let request = emptyRequest, let engine = NativeMailCenter.activeEngine else { return }
        emptyRequest = nil
        let name = request.mailbox.name, count = request.uids.count
        banner = "Emptying \(name)…"
        Task { @MainActor [weak self] in
            do {
                try await engine.empty(request.mailbox.rowID, uids: request.uids, validity: request.validity)
                self?.banner = "Deleted \(count) message\(count == 1 ? "" : "s") from \(name) permanently."
                self?.reload()
            } catch { self?.banner = "\(name) was not emptied: " + error.localizedDescription }
        }
    }
    func toggleFlag() {
        guard let message = selected, let box = actionBox(message) else { return }
        let flagged = !message.flagged
        perform(flagged ? "flag" : "unflag") { try await MailActions.setFlagged(flagged, message, in: box) } update: { $0.flagged = flagged }
    }
    func toggleRead() {
        guard let message = selected, actionBox(message) != nil else { return }
        readTimer?.cancel()
        // Marked unread, the message stays unread while it stays on screen, also when you come back to the window.
        keptUnread = message.read ? message.rowID : nil
        setRead(!message.read, message)
    }
    /// Where the selected message can move: the other mailboxes of its account.
    var moveDestinations: [MailMailbox] {
        guard let message = selected, let box = actionBox(message) else { return [] }
        return mailboxes.filter { $0.accountID == box.accountID && $0.rowID != box.rowID }.sorted { $0.path < $1.path }
    }
    func move(to destination: MailMailbox) {
        guard let message = selected, let box = actionBox(message) else { return }
        perform("move", removes: true) { try await MailActions.move(message, from: box, to: destination) }
    }
    func openInMail() {
        guard let message = selected, let box = actionBox(message) else { return }
        // You now use Mail itself, so closing the inbox leaves it running.
        MailActions.openedByUser = true
        Task { @MainActor [weak self] in
            do { try await MailActions.openInMail(message, in: box) } catch { self?.banner = error.localizedDescription }
        }
    }
    func checkMail() {
        Task { @MainActor [weak self] in
            do { try await MailActions.checkForNewMail(); self?.banner = "Checking for new mail…" }
            catch { self?.banner = error.localizedDescription }
        }
    }

    func moveSelection(_ delta: Int) {
        guard !messages.isEmpty else { return }
        let index = messages.firstIndex { $0.rowID == selectedID } ?? 0
        let next = min(max(index + delta, 0), messages.count - 1)
        selectedID = messages[next].rowID
        if next >= messages.count - 30 { loadNextPage() }
    }

    // MARK: AI writing

    private var messageText: String? {
        guard let detail, let message = selected else { return nil }
        return "From: \(message.sender) <\(message.senderAddress)>\nSubject: \(message.subject)\nDate: \(message.date.formatted())\n\n" + String(detail.readableText.prefix(30_000))
    }

    func summarise() {
        guard let text = messageText, !aiWritingBusy else { return }
        aiWritingBusy = true
        let id = selectedID
        Task { @MainActor [weak self] in
            defer { self?.aiWritingBusy = false }
            do {
                let reply = try await self?.aiWriting(.summarise(message: text))
                guard self?.selectedID == id else { return }
                self?.summary = reply?.text
            } catch { self?.banner = error.localizedDescription }
        }
    }
}

/// A flag a running query checks, so a newer list can stop an older one's SQL.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.withLock { stopped = true } }
    var isStopped: Bool { lock.withLock { stopped } }
    /// For `MailStore.page(stop:)`.
    var check: () -> Bool { { [self] in isStopped } }
}
