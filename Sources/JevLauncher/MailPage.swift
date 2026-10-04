import AppKit
import Combine
import SwiftUI
import LauncherCore

/// Mail in the launcher panel: the inbox list on the left and the selected message on the right.
/// It uses the mail window's model and views. ↑↓ move and preview, a previewed message is marked
/// read, Return opens it in Mail, ⌫ deletes, and ⌘O moves to the mail window. Letters always type
/// in the filter, so replies use Apple Mail's keys: ⌘R, ⇧⌘R, and ⇧⌘F to forward.
/// A reply is written in the panel: the panel is the key window, so text boxes take typing
/// without activating the app.
@MainActor
final class MailPage: ObservableObject, LauncherPage {
    let id = ViewID.mail
    /// Nil for snapshot runs, which show the empty inbox and never read Mail.
    let mail: MailModel?
    private let popOutAction: ((Int64?) -> Void)?
    /// Gives the keys back to the filter field, such as after the composer closes.
    let focusFilter: (() -> Void)?
    /// A kept draft stays in the model but steps aside while a message picked in the search shows.
    @Published var draftHidden = false
    /// The message fills the panel and the list hides. Escape returns to two panes first.
    @Published var expanded = false
    /// An empty model for snapshot runs, which never read Mail.
    private lazy var empty = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false })

    private var draftWatch: AnyCancellable?

    init(mail: MailModel?, popOut: ((Int64?) -> Void)?, focusFilter: (() -> Void)? = nil) {
        self.mail = mail; self.popOutAction = popOut; self.focusFilter = focusFilter
        // A new draft, such as from the reader's Reply button, shows at once. So does the open
        // draft when a new one was refused.
        guard let mail else { return }
        let newDraft = mail.$draft.map { $0?.id }.removeDuplicates().dropFirst().map { _ in () }
        draftWatch = newDraft.merge(with: mail.$draftNudge.dropFirst().map { _ in () })
            .sink { [weak self] in MainActor.assumeIsolated { self?.draftHidden = false } }
    }

    private var model: MailModel { mail ?? empty }
    var isTyping: Bool { mail?.draft != nil && !draftHidden }
    var canPopOut: Bool { mail != nil && popOutAction != nil }
    func popOut() { popOutAction?(mail?.selectedID) }

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
        // An open reply stays in the model, so the mail window or the next visit shows it.
        if !handingOff { mail.stop() }
    }

    /// Opens one message, such as a row picked in the search.
    /// The message counts as read only once it loads and is selected, not the one selected before.
    func show(_ rowID: Int64) {
        guard let mail, mail.open(rowID) else { return }
        mail.windowIsKey = true
        if let draft = mail.draft {
            draftHidden = true
            mail.banner = "Your unsent \(draft.noun) is kept. Press Escape to go back to it."
        }
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
        case .open: if mail.selected != nil { mail.openInMail() }
        case .delete: mail.delete()
        case .left, .right: return false
        }
        return true
    }

    /// Space expands or restores the message while the filter is empty. ⌘R replies, ⇧⌘R replies
    /// to all, and ⇧⌘F forwards, as in Apple Mail; plain letters always type in the filter. Keys
    /// are read as characters, so they match the key caps on every keyboard layout.
    func handleEvent(_ event: NSEvent) -> Bool {
        guard let mail, !isTyping else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "z", mail.pendingSend != nil { mail.undoSend(); return true }
        guard mail.selected != nil else { return false }
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
        guard mail?.selected != nil else { return [] }
        return [("Reply", "⌘R"), ("Forward", "⇧⌘F"), (expanded ? "List" : "Expand", "Space")]
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
    @AppStorage(MailReading.splitKey) private var splitRaw = MailReading.Split.balanced.rawValue
    private var split: MailReading.Split { MailReading.Split(rawValue: splitRaw) ?? .balanced }

    var body: some View {
        Group {
            if !ready {
                MailSetupView(model: mail, needsAccess: needsAccess)
            } else if composing {
                // The composer takes the panel, as Apple Mail's does; a reply shows its original inside.
                ComposeView(model: mail).id(mail.draft?.id)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        if !(page.expanded && mail.selected != nil) {
                            list.frame(width: geo.size.width * split.listFraction)
                            Divider()
                        }
                        MailReader(model: mail, expanded: $page.expanded, inPanel: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        // The filter takes the keys again once the composer closes or steps aside.
        .onChange(of: composing) { _, now in if !now { DispatchQueue.main.async { page.focusFilter?() } } }
        // Above the composer's footer while one is open, so the note never covers Send.
        .overlay(alignment: .bottom) { MailBanner(model: mail).padding(.bottom, composing ? 58 : 12) }
        .sheet(isPresented: Binding(get: { mail.showsOutbox && !composing }, set: { mail.showsOutbox = $0 })) { MailDeliveryView(model: mail) }
    }

    private var composing: Bool { mail.draft != nil && !page.draftHidden }

    private var ready: Bool { if snapshot { return true }; if case .ready = mail.status { return true }; return false }
    private var needsAccess: Bool { if case .needsFullDiskAccess = mail.status { return true }; return false }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    MailPlacePicker(model: mail).font(.headline)
                    MailEmptyButton(model: mail)
                    Spacer()
                    Button { mail.showsOutbox = true } label: { Image(systemName: "tray.and.arrow.up") }.buttonStyle(.borderless).help("Outbox and send history")
                }
                MailClosedNote(model: mail)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            // A double click opens the message in Mail without delaying a single click's selection.
            MailMessageList(model: mail, scrollsToSelection: true) { id in
                mail.select(id, byUser: true); _ = page.handle(.open(shift: false))
            }
            .scrollContentBackground(.hidden)
        }
    }
}
