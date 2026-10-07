import AppKit
import Combine
import SwiftUI
import LauncherCore

/// Mail lives only in the launcher panel: the mailbox sidebar, the message list, and the selected
/// message or the open draft. ↑↓ move and preview, a previewed message is marked read, Return or a
/// double click reads it across the panel, ⌫ deletes, and ⌘N writes a new message. Letters always
/// type in the filter, so replies use Apple Mail's keys: ⌘R, ⇧⌘R, and ⇧⌘F to forward.
/// A reply is written in the panel: the panel is the key window, so text boxes take typing
/// without activating the app.
@MainActor
final class MailPage: ObservableObject, LauncherPage {
    let id = ViewID.mail
    /// Nil for snapshot runs, which show the empty inbox and never read Mail.
    let mail: MailModel?
    /// Gives the keys back to the filter field, such as after the composer closes.
    let focusFilter: (() -> Void)?
    /// A kept draft stays in the model but steps aside while another message shows.
    @Published var draftHidden = false
    /// The message fills the panel and the sidebar and list hide. Escape shows them again first.
    @Published var expanded = false
    /// The mailbox sidebar. On each time Mail opens; the list's button hides it for more room.
    @Published var showsSidebar = true
    /// An empty model for snapshot runs, which never read Mail.
    private lazy var empty = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false })

    private var draftWatch: AnyCancellable?

    init(mail: MailModel?, focusFilter: (() -> Void)? = nil) {
        self.mail = mail; self.focusFilter = focusFilter
        // A new draft, such as from the reader's Reply button, shows at once. So does the open
        // draft when a new one was refused or the open one was picked again.
        guard let mail else { return }
        let newDraft = mail.$draft.map { $0?.id }.removeDuplicates().dropFirst().map { _ in () }
        draftWatch = newDraft.merge(with: mail.$draftNudge.dropFirst().map { _ in () })
            .sink { [weak self] in MainActor.assumeIsolated { self?.draftHidden = false } }
    }

    private var model: MailModel { mail ?? empty }
    var isTyping: Bool { composing }
    /// True while the composer is on screen.
    var composing: Bool { mail?.draft != nil && !draftHidden }
    var openTitle: String { mail?.place != .outbox && mail?.selected != nil ? "Read" : "" }

    func opened() {
        guard let mail else { return }
        mail.start()
        // A message picked in the search moves to its mailbox after this; otherwise the view starts
        // on the inbox, at its newest message. An open reply keeps its place.
        mail.place = .inbox
        if mail.draft == nil { mail.showNewest() }
        expanded = MailReading.split == .messageOnly
        // The preview is always on screen, so a message you move to counts as read after a moment.
        mail.windowIsKey = true
    }
    func closed(handingOff: Bool) {
        guard let mail else { return }
        mail.windowIsKey = false
        if mail.discardArmed { mail.discardArmed = false; mail.composeNote = nil }
        expanded = false
        // An open reply stays in the model, so the next visit shows it.
        mail.stop()
    }

    /// Opens one message, such as a row picked in the search.
    /// The message counts as read only once it loads and is selected, not the one selected before.
    func show(_ rowID: Int64) {
        guard let mail, mail.open(rowID) else { return }
        mail.windowIsKey = true
        keepDraft()
    }

    /// A message clicked in the list. An open draft steps aside and is kept; Escape brings it back.
    func pick(_ rowID: Int64) {
        guard let mail else { return }
        mail.select(rowID, byUser: true)
        keepDraft()
        // A click gives the list the keys; letters type in the filter again.
        if !composing { DispatchQueue.main.async { [weak self] in self?.focusFilter?() } }
    }

    /// Return or a double click: the selected message across the panel, counted as read. It never
    /// opens Apple Mail; Open in Mail is in the ⋯ menu.
    func read(_ rowID: Int64? = nil) {
        guard let mail else { return }
        if let rowID { pick(rowID) }
        guard mail.place != .outbox, let selected = mail.selectedID else { return }
        mail.select(selected, byUser: true)
        expanded = true
    }

    private func keepDraft() {
        guard let draft = mail?.draft, !draftHidden else { return }
        draftHidden = true
        mail?.banner = "Your unsent \(draft.noun) is kept. Press Escape to go back to it."
    }

    /// The filter only narrows the list. A message the filter selects by itself counts as read once
    /// the filter stops changing, since its first match changes as you type.
    func filter(_ text: String) {
        guard let mail, mail.search != text else { return }
        mail.search = text
    }

    func handle(_ key: PageKey) -> Bool {
        guard let mail else { return true }
        switch key {
        case .down: mail.moveSelection(1)
        case .up: mail.moveSelection(-1)
        case .open: read()
        case .delete: mail.delete()
        case .left, .right: return false
        }
        return true
    }

    /// Space expands or restores the message while the filter is empty. ⌘N writes a new message,
    /// ⌘R replies, ⇧⌘R replies to all, and ⇧⌘F forwards, as in Apple Mail; plain letters always
    /// type in the filter. Keys are read as characters, so they match the key caps on every layout.
    func handleEvent(_ event: NSEvent) -> Bool {
        guard let mail, !isTyping else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "z", mail.pendingSend != nil { mail.undoSend(); return true }
        if flags == .command, key == "n" { mail.compose(); return true }
        guard mail.place != .outbox, mail.selected != nil else { return false }
        if key == " ", flags.isEmpty, mail.search.isEmpty {
            expanded.toggle()
            return true
        }
        switch (key, flags) {
        case ("r", .command): mail.reply(all: false)
        case ("r", [.command, .shift]): mail.reply(all: true)
        case ("f", [.command, .shift]): mail.forward()
        default: return false
        }
        return true
    }

    var footerHints: [(title: String, key: String)] {
        if isTyping { return [("Send", "⌘↩")] }
        guard mail?.place != .outbox, mail?.selected != nil else { return [("New", "⌘N")] }
        return [("Reply", "⌘R"), ("Forward", "⇧⌘F"), (expanded ? "List" : "Expand", "Space"), ("New", "⌘N")]
    }
    var backTitle: String? { isTyping ? "Discard" : nil }
    var footerChanges: AnyPublisher<Void, Never> {
        let own = objectWillChange.map { _ in () }
        guard let mail else { return own.eraseToAnyPublisher() }
        return own.merge(with: mail.objectWillChange.map { _ in () }).eraseToAnyPublisher()
    }

    /// Escape: discards the open draft (twice when it has text), then shows a kept one, then
    /// leaves the expanded message.
    func back() -> Bool {
        if let mail, mail.draft != nil, !draftHidden {
            mail.discardDraft()
            return true
        }
        if draftHidden { draftHidden = false; return true }
        if expanded { expanded = false; return true }
        return false
    }

    func content() -> AnyView { AnyView(MailPageView(page: self, mail: model, snapshot: mail == nil)) }
}

private struct MailPageView: View {
    @ObservedObject var page: MailPage
    @ObservedObject var mail: MailModel
    let snapshot: Bool

    var body: some View {
        Group {
            if ready { MailWorkspace(page: page, mail: mail) } else { MailSetupView(model: mail, needsAccess: needsAccess) }
        }
        // The filter takes the keys again once the composer closes or steps aside, or a mailbox is picked.
        .onChange(of: page.composing) { _, now in if !now { DispatchQueue.main.async { page.focusFilter?() } } }
        .onChange(of: mail.place) { _, _ in if !page.composing { DispatchQueue.main.async { page.focusFilter?() } } }
        // Above the composer's footer while one is open, so the note never covers Send.
        .overlay(alignment: .bottom) { MailBanner(model: mail).padding(.bottom, page.composing ? 58 : 12) }
    }

    private var ready: Bool { if snapshot { return true }; if case .ready = mail.status { return true }; return false }
    private var needsAccess: Bool { if case .needsFullDiskAccess = mail.status { return true }; return false }
}
