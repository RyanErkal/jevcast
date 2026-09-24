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
    @Published private(set) var messages: [MailSummary] = []
    @Published var selectedID: Int64? { didSet { if oldValue != selectedID { loadSelected() } } }
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

    func stop() { poll?.cancel(); poll = nil }

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
            guard let (messages, boxes) = result else { self.banner = "Mail's index could not be read. Try again in a moment."; return }
            self.messages = messages
            if !boxes.isEmpty { self.mailboxes = boxes }
            if keepSelection, let previous, messages.contains(where: { $0.rowID == previous }) { return }
            if self.selectedID == nil || !messages.contains(where: { $0.rowID == self.selectedID }) { self.selectedID = messages.first?.rowID }
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

    private func loadSelected() {
        detail = nil; detailMissing = false; summary = nil
        guard let root, let message = selected, let box = mailbox(message.mailbox) else { return }
        let rowID = message.rowID
        Task { @MainActor [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) { MailStore.message(root: root, mailbox: box, rowID: rowID) }.value
            guard let self, self.selectedID == rowID else { return }
            self.detail = parsed
            self.detailMissing = parsed == nil
            // Opening a message marks it read, as Mail does.
            if !message.read { self.perform("mark read") { try await MailActions.setRead(true, message, in: box) } update: { $0.read = true } }
        }
    }

    // MARK: Actions

    /// Runs a Mail action. `update` changes the row at once; the index confirms it later.
    private func perform(_ name: String, removes: Bool = false, _ action: @escaping () async throws -> Void, update: ((inout MailSummary) -> Void)? = nil) {
        guard let message = selected else { return }
        let index = messages.firstIndex { $0.rowID == message.rowID }
        if removes, let index {
            messages.remove(at: index)
            selectedID = messages.indices.contains(index) ? messages[index].rowID : messages.last?.rowID
        } else if let index, let update { update(&messages[index]) }
        Task { @MainActor [weak self] in
            do { try await action() }
            catch {
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
    func delete() {
        guard let message = selected, let box = mailbox(message.mailbox) else { return }
        perform("delete", removes: true) { try await MailActions.delete(message, in: box) }
    }
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
