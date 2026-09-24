import AppKit
import LauncherCore

/// The mail window's state. Lists come from Mail's index; changes go through Apple Mail;
/// the list updates when Mail's index changes.
@MainActor
final class MailModel: ObservableObject {
    enum Place: Hashable {
        case inbox, unread, flagged
        case mailbox(Int64)
    }
    struct Draft: Equatable {
        enum Mode: Equatable { case new, reply(all: Bool), forward }
        var mode: Mode = .new
        var to = ""
        var cc = ""
        var subject = ""
        var body = ""
        var instruction = ""
        /// The message a reply or forward answers.
        var original: MailSummary?
    }

    @Published private(set) var status: MailStore.Status = .noMail
    @Published private(set) var mailboxes: [MailMailbox] = []
    @Published var place: Place = .inbox { didSet { if oldValue != place { selectedID = nil; reload() } } }
    @Published var search = "" { didSet { if oldValue != search { reloadSoon() } } }
    /// The search field shows only while searching.
    @Published var searching = false
    /// Web images in HTML mail. On by default; the ⋯ menu turns them off.
    @Published var loadsImages = UserDefaults.standard.object(forKey: "mailLoadsImages") as? Bool ?? true {
        didSet { UserDefaults.standard.set(loadsImages, forKey: "mailLoadsImages") }
    }
    /// True while the mail window has the keyboard, so a message counts as read only when seen.
    var windowIsKey = false
    /// True when Jevcast started Apple Mail for this session, so it can quit it again after.
    private var startedMail = false
    private var readTimer: Task<Void, Never>?
    @Published private(set) var messages: [MailSummary] = []
    /// Setting this from the list or the keyboard marks the message read. The model's own
    /// selections, after a reload, use `select(_:byUser:)` with false and change nothing.
    @Published var selectedID: Int64? {
        didSet { if oldValue != selectedID { loadSelected(markRead: !selectingQuietly) } }
    }
    private var selectingQuietly = false
    /// A message to select once the list that holds it loads, such as one picked in the launcher.
    private var pending: Int64?
    @Published private(set) var detail: MIMEMessage?
    @Published private(set) var detailMissing = false
    @Published var banner: String?
    @Published var draft: Draft?
    @Published private(set) var sending = false
    @Published private(set) var summary: String?
    @Published private(set) var lunaBusy = false

    private let luna: (LunaRequest) async throws -> LunaReply
    private let lunaAllowed: () -> Bool
    private var root: String? { if case .ready(let root) = status { return root }; return nil }
    private var fingerprint = ""
    private var poll: Task<Void, Never>?
    private var searchWork: Task<Void, Never>?
    private var loadWork: Task<Void, Never>?
    /// Parsed bodies of recent messages, so moving back and forth shows them at once.
    private var bodies: [Int64: MIMEMessage] = [:]
    private var bodyOrder: [Int64] = []
    /// Messages removed here whose change Mail has not written to its index yet. A refresh in the
    /// meantime must not bring them back.
    private var removing: [Int64: Date] = [:]
    /// Mail actions run one after another, so quick deletes never race each other.
    private var actionChain: Task<Void, Never>?

    init(luna: @escaping (LunaRequest) async throws -> LunaReply, lunaAllowed: @escaping () -> Bool) {
        self.luna = luna; self.lunaAllowed = lunaAllowed
    }

    var selected: MailSummary? { messages.first { $0.rowID == selectedID } }
    func mailbox(_ id: Int64) -> MailMailbox? { mailboxes.first { $0.rowID == id } }
    var inboxes: [MailMailbox] { mailboxes.filter { $0.role == .inbox } }
    var accounts: [String] { Array(Set(mailboxes.map(\.accountID))).sorted() }
    var unreadInInbox: Int { inboxes.map(\.unread).reduce(0, +) }
    var canUseLuna: Bool { lunaAllowed() }

    // MARK: Loading

    /// Checks access, loads mailboxes, and starts watching Mail's index while the window is open.
    func start() {
        refreshStatus()
        if root != nil { fetchNewMail() }
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, let root = self.root else { continue }
                let current = await Task.detached { MailStore.fingerprint(root: root) }.value
                if current != self.fingerprint { self.fingerprint = current; self.reload(keepSelection: true) }
            }
        }
    }

    /// Closing the inbox quits Apple Mail when Jevcast started it, once pending changes are done,
    /// so nothing extra runs between checks.
    func stop() {
        poll?.cancel(); poll = nil; readTimer?.cancel()
        guard startedMail else { return }
        startedMail = false
        let pending = actionChain
        Task { @MainActor in
            await pending?.value
            // An action that started after closing, or Mail opened by you, keeps it running.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let mail = NSRunningApplication.runningApplications(withBundleIdentifier: MailActions.bundleID).first,
                  !MailActions.openedByUser else { return }
            mail.terminate()
        }
    }

    /// Starts Apple Mail hidden, if needed, and asks it to fetch new mail. New mail reaches the
    /// index only while Mail runs.
    private func fetchNewMail() {
        let wasRunning = AppleScript.isRunning(MailActions.bundleID)
        if !wasRunning { startedMail = true; MailActions.openedByUser = false }
        Task { @MainActor [weak self] in
            do { try await MailActions.checkForNewMail() } catch { self?.banner = "Could not check for new mail: " + error.localizedDescription }
        }
    }

    func refreshStatus() {
        status = MailStore.status()
        guard let root else { mailboxes = []; messages = []; return }
        fingerprint = MailStore.fingerprint(root: root)
        mailboxes = (try? MailStore.mailboxes(root: root)) ?? []
        reload()
    }

    private func reloadSoon() {
        searchWork?.cancel()
        searchWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload(keepSelection: Bool = false) {
        guard let root else { return }
        let query = self.query
        let previous = selectedID
        loadWork?.cancel()
        loadWork = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([MailSummary], [MailMailbox])? in
                guard let messages = try? MailStore.messages(root: root, query) else { return nil }
                return (messages, (try? MailStore.mailboxes(root: root)) ?? [])
            }.value
            guard !Task.isCancelled, let self else { return }
            guard let (fetched, boxes) = result else { self.banner = "Mail's index could not be read. Try again in a moment."; return }
            // Removals older than two minutes are Mail's business again.
            self.removing = self.removing.filter { Date().timeIntervalSince($0.value) < 120 }
            let messages = fetched.filter { self.removing[$0.rowID] == nil }
            self.messages = messages
            if !boxes.isEmpty { self.mailboxes = boxes }
            if let pending = self.pending {
                self.pending = nil
                if !messages.contains(where: { $0.rowID == pending }),
                   let found = try? MailStore.messages(root: root, .init(mailboxes: [], rowIDs: [pending])).first {
                    self.messages.insert(found, at: self.messages.firstIndex { $0.date < found.date } ?? self.messages.count)
                }
                self.select(pending, byUser: true)
                return
            }
            if keepSelection, let previous, messages.contains(where: { $0.rowID == previous }) { return }
            // A message that left the list is not replaced by one that would be marked read.
            if self.selectedID == nil || !messages.contains(where: { $0.rowID == self.selectedID }) { self.select(messages.first?.rowID, byUser: false) }
        }
    }

    private var query: MailStore.Query {
        switch place {
        case .inbox: return .init(mailboxes: inboxes.map(\.rowID), text: search)
        case .unread: return .init(mailboxes: inboxes.map(\.rowID), text: search, unreadOnly: true)
        case .flagged: return .init(mailboxes: [], text: search, flaggedOnly: true)
        case .mailbox(let id): return .init(mailboxes: [id], text: search)
        }
    }

    func select(_ rowID: Int64?, byUser: Bool) {
        let unchanged = rowID == selectedID
        selectingQuietly = !byUser
        selectedID = rowID
        selectingQuietly = false
        // The same row again, such as a message the list just inserted, still needs its body.
        if unchanged, detail == nil, !detailMissing { loadSelected(markRead: byUser) }
    }

    /// Opens one message from the launcher: its own mailbox, selected once the list loads.
    func open(_ rowID: Int64) {
        guard let root, let found = try? MailStore.messages(root: root, .init(mailboxes: [], rowIDs: [rowID])).first else { return }
        pending = rowID
        let target = Place.mailbox(found.mailbox)
        if place == target { reload() } else { place = target }
    }

    private var loadingID: Int64?

    private func loadSelected(markRead: Bool) {
        summary = nil
        guard let root, let message = selected, let box = mailbox(message.mailbox) else { detail = nil; detailMissing = false; return }
        let rowID = message.rowID
        loadingID = rowID
        markReadSoon(message, in: box)
        if let cached = bodies[rowID] {
            detail = cached; detailMissing = false
            prefetchNeighbours(of: rowID, root: root)
            return
        }
        detail = nil; detailMissing = false
        Task { @MainActor [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) { MailStore.message(root: root, mailbox: box, rowID: rowID) }.value
            guard let self else { return }
            if let parsed { self.remember(parsed, for: rowID) }
            guard self.selectedID == rowID, self.loadingID == rowID else { return }
            self.detail = parsed
            self.detailMissing = parsed == nil
            self.prefetchNeighbours(of: rowID, root: root)
        }
    }

    /// A message on screen for a second, in the window you are using, counts as read, as in Mail.
    /// Moving past it quickly with ↓ leaves it unread.
    private func markReadSoon(_ message: MailSummary, in box: MailMailbox) {
        readTimer?.cancel()
        guard !message.read else { return }
        readTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self, self.windowIsKey, self.selectedID == message.rowID,
                  self.selected?.read == false else { return }
            self.perform("mark read") { try await MailActions.setRead(true, message, in: box) } update: { $0.read = true }
        }
    }

    private func remember(_ body: MIMEMessage, for rowID: Int64) {
        if bodies[rowID] == nil { bodyOrder.append(rowID) }
        bodies[rowID] = body
        while bodyOrder.count > 40 { bodies.removeValue(forKey: bodyOrder.removeFirst()) }
    }

    /// Reads the messages above and below in the background, so the next one opens at once.
    private func prefetchNeighbours(of rowID: Int64, root: String) {
        guard let index = messages.firstIndex(where: { $0.rowID == rowID }) else { return }
        let wanted = [index + 1, index + 2, index - 1].filter(messages.indices.contains).map { messages[$0] }
            .filter { bodies[$0.rowID] == nil }
            .compactMap { message in mailbox(message.mailbox).map { (message.rowID, $0) } }
        guard !wanted.isEmpty else { return }
        Task { @MainActor [weak self] in
            for (id, box) in wanted {
                if let parsed = await Task.detached(priority: .utility, operation: { MailStore.message(root: root, mailbox: box, rowID: id) }).value {
                    self?.remember(parsed, for: id)
                }
            }
        }
    }

    // MARK: Actions

    /// Runs a Mail action. `update` changes the row at once; the index confirms it later.
    private func perform(_ name: String, removes: Bool = false, _ action: @escaping () async throws -> Void, update: ((inout MailSummary) -> Void)? = nil) {
        guard let message = selected else { return }
        let index = messages.firstIndex { $0.rowID == message.rowID }
        if removes, let index {
            removing[message.rowID] = Date()
            messages.remove(at: index)
            // The next message shows but stays unread until you pick it.
            select(messages.indices.contains(index) ? messages[index].rowID : messages.last?.rowID, byUser: false)
        } else if let index, let update { update(&messages[index]) }
        let previous = actionChain
        actionChain = Task { @MainActor [weak self] in
            await previous?.value
            do { try await action() }
            catch {
                self?.removing.removeValue(forKey: message.rowID)
                self?.banner = "Could not \(name): \(error.localizedDescription)"
                self?.reload(keepSelection: true)
            }
        }
    }

    func archive() {
        guard let message = selected, let box = mailbox(message.mailbox) else { return }
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
    func delete() {
        guard let message = selected, let box = mailbox(message.mailbox) else { return }
        perform("delete", removes: true) { try await MailActions.delete(message, in: box) }
    }
    /// Deletes every message in the list from the selected message's sender: for clearing out junk.
    func deleteAllFromSender() {
        guard let sender = selected?.senderAddress, !sender.isEmpty else { return }
        let targets = messages.filter { $0.senderAddress.caseInsensitiveCompare(sender) == .orderedSame }
        for message in targets { delete(message.rowID) }
        banner = "Deleting \(targets.count) message" + (targets.count == 1 ? "" : "s") + " from \(sender)."
    }
    var selectedSender: String? { selected?.senderAddress }
    func toggleFlag() {
        guard let message = selected, let box = mailbox(message.mailbox) else { return }
        let flagged = !message.flagged
        perform(flagged ? "flag" : "unflag") { try await MailActions.setFlagged(flagged, message, in: box) } update: { $0.flagged = flagged }
    }
    func toggleRead() {
        guard let message = selected, let box = mailbox(message.mailbox) else { return }
        let read = !message.read
        perform(read ? "mark read" : "mark unread") { try await MailActions.setRead(read, message, in: box) } update: { $0.read = read }
    }
    func move(to destination: MailMailbox) {
        guard let message = selected, let box = mailbox(message.mailbox) else { return }
        perform("move", removes: true) { try await MailActions.move(message, from: box, to: destination) }
    }
    func openInMail() {
        guard let message = selected, let box = mailbox(message.mailbox) else { return }
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
        selectedID = messages[min(max(index + delta, 0), messages.count - 1)].rowID
    }

    // MARK: Compose

    func compose(to address: String = "") { draft = Draft(to: address) }

    func reply(all: Bool) {
        guard let message = selected else { return }
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: " + message.subject
        draft = Draft(mode: .reply(all: all), to: message.senderAddress, subject: subject, original: message)
    }

    func forward() {
        guard let message = selected else { return }
        let subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: " + message.subject
        draft = Draft(mode: .forward, subject: subject, original: message)
    }

    func send() {
        guard let draft, !sending else { return }
        sending = true
        Task { @MainActor [weak self] in
            defer { self?.sending = false }
            do {
                switch draft.mode {
                case .new:
                    try await MailActions.send(to: MailActions.addresses(draft.to), cc: MailActions.addresses(draft.cc), subject: draft.subject, body: draft.body)
                case .reply(let all):
                    guard let original = draft.original, let box = self?.mailbox(original.mailbox) else { return }
                    try await MailActions.reply(original, in: box, text: draft.body, all: all)
                case .forward:
                    guard let original = draft.original, let box = self?.mailbox(original.mailbox) else { return }
                    try await MailActions.forward(original, in: box, text: draft.body, to: MailActions.addresses(draft.to))
                }
                self?.draft = nil
                self?.banner = "Sent."
            } catch {
                self?.banner = "Not sent: " + error.localizedDescription
            }
        }
    }

    // MARK: Luna

    private var messageText: String? {
        guard let detail, let message = selected else { return nil }
        return "From: \(message.sender) <\(message.senderAddress)>\nSubject: \(message.subject)\nDate: \(message.date.formatted())\n\n" + String(detail.readableText.prefix(30_000))
    }

    func summarise() {
        guard let text = messageText, !lunaBusy else { return }
        lunaBusy = true
        let id = selectedID
        Task { @MainActor [weak self] in
            defer { self?.lunaBusy = false }
            do {
                let reply = try await self?.luna(.summarise(message: text))
                guard self?.selectedID == id else { return }
                self?.summary = reply?.text
            } catch { self?.banner = error.localizedDescription }
        }
    }

    /// Writes the reply body from the instruction in the draft, such as "yes, but next week".
    func draftWithLuna() {
        guard var current = draft, !lunaBusy else { return }
        let source: String
        if let text = messageText, current.original?.rowID == selectedID { source = text } else { source = "(No original message.)\nSubject: " + current.subject }
        lunaBusy = true
        let instruction = current.instruction
        Task { @MainActor [weak self] in
            defer { self?.lunaBusy = false }
            do {
                guard let reply = try await self?.luna(.reply(message: source, instruction: instruction)) else { return }
                current = self?.draft ?? current
                current.body = reply.text
                self?.draft = current
            } catch { self?.banner = error.localizedDescription }
        }
    }
}
