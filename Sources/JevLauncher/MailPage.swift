import AppKit
import SwiftUI
import LauncherCore

/// Mail in the launcher panel: the inbox list on the left and the selected message on the right.
/// It uses the mail window's model and views. ↑↓ move and preview, a previewed message is marked
/// read, Return opens it in Mail, ⌫ deletes, and ⌘O moves to the mail window.
/// A reply is written in the panel: the panel is the key window, so text boxes take typing
/// without activating the app.
@MainActor
final class MailPage: ObservableObject, LauncherPage {
    let id = ViewID.mail
    /// Nil for snapshot runs, which show the empty inbox and never read Mail.
    let mail: MailModel?
    private let popOutAction: ((Int64?) -> Void)?
    /// A kept reply stays in the model but steps aside while a message picked in the search shows.
    @Published var draftHidden = false
    /// A reply with text needs a second Escape before it is discarded.
var discardArmed = false
    /// An empty model for snapshot runs, which never read Mail.
    private lazy var empty = MailModel(luna: { _ in throw CancellationError() }, lunaAllowed: { false })

    init(mail: MailModel?, popOut: ((Int64?) -> Void)?) { self.mail = mail; self.popOutAction = popOut }

    private var model: MailModel { mail ?? empty }
    var isTyping: Bool { mail?.draft != nil && !draftHidden }
    var canPopOut: Bool { mail != nil && popOutAction != nil }
    func popOut() { popOutAction?(mail?.selectedID) }

    func opened() {
        guard let mail else { return }
        mail.start()
        // A message picked in the search moves to its mailbox after this; otherwise the view starts on the inbox.
        mail.place = .inbox
        // The preview is always on screen, so a message you move to counts as read after a moment.
        mail.windowIsKey = true
    }
    func closed(handingOff: Bool) {
        guard let mail else { return }
        mail.windowIsKey = false
        discardArmed = false
        // An open reply stays in the model, so the mail window or the next visit shows it.
        if !handingOff { mail.stop() }
    }

    /// Opens one message, such as a row picked in the search.
    /// The message counts as read only once it loads and is selected, not the one selected before.
    func show(_ rowID: Int64) {
        guard let mail, mail.open(rowID) else { return }
        mail.windowIsKey = true
        if mail.draft != nil {
            draftHidden = true
            mail.banner = "Your unsent reply is kept. Press Escape to go back to it."
        }
    }

    /// The filter only narrows the list. A message the filter selects by itself is not marked read.
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

    func back() -> Bool {
        if let mail, let draft = mail.draft, !draftHidden {
            if !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !discardArmed {
                discardArmed = true
                mail.banner = "Press Escape again to discard this reply."
                return true
            }
            discardArmed = false
            mail.draft = nil
            return true
        }
        if draftHidden { draftHidden = false; return true }
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
            if !ready {
                MailSetupView(model: mail, needsAccess: needsAccess)
            } else if mail.draft != nil && !page.draftHidden {
                ScrollView { ComposeView(model: mail).frame(maxWidth: .infinity) }
            } else {
                HStack(spacing: 0) {
                    // Half and half: a narrower message shows more of its length.
                    list.frame(maxWidth: .infinity)
                    Divider()
                    MailReader(model: mail).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // A new reply, such as from the reader's Reply button, shows at once.
        .onChange(of: mail.draft?.mode) { _, _ in page.draftHidden = false }
        .onChange(of: mail.draft?.body) { _, _ in page.discardArmed = false }
        .overlay(alignment: .bottom) {
            if let banner = mail.banner {
                Text(banner).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 12)
                    .onTapGesture { mail.banner = nil }
                    .task(id: banner) { try? await Task.sleep(nanoseconds: 4_000_000_000); if mail.banner == banner { mail.banner = nil } }
            }
        }
    }

    private var ready: Bool { if snapshot { return true }; if case .ready = mail.status { return true }; return false }
    private var needsAccess: Bool { if case .needsFullDiskAccess = mail.status { return true }; return false }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $mail.selectedID) {
                ForEach(mail.messages) { message in
                    MailRow(message: message, delete: { mail.delete(message.rowID) },
                            deleteAll: { mail.select(message.rowID, byUser: false); mail.deleteAllFromSender() })
                        .tag(message.rowID).id(message.rowID)
                }
            }
            // A double click opens the message in Mail without delaying a single click's selection.
            .contextMenu(forSelectionType: Int64.self, menu: { _ in }) { ids in
                guard let id = ids.first else { return }
                mail.select(id, byUser: true); _ = page.handle(.open(shift: false))
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .overlay { if mail.messages.isEmpty { Text(mail.search.isEmpty ? "Inbox is empty" : "No matches").foregroundStyle(.secondary) } }
            .onChange(of: mail.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }
}
