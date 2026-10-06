import AppKit
import LauncherCore
import SwiftUI

/// Invented composition state only. No store, account, credential, or send path is used.
@MainActor
enum MailSnapshots {
    static var windows: [(String, AnyView, NSSize)] {
        [
            ("mail-compose", AnyView(composer()), NSSize(width: 640, height: 520)),
            ("mail-reply", AnyView(reply()), NSSize(width: 820, height: 760)),
            ("mail-outbox", AnyView(outbox()), NSSize(width: 540, height: 310)),
            ("mail-workspace", AnyView(workspace()), NSSize(width: 1140, height: 700)),
            ("mail-workspace-compact", AnyView(workspace(compact: true)), NSSize(width: 900, height: 640)),
            ("mail-workspace-drafts", AnyView(workspace(drafts: true)), NSSize(width: 1140, height: 700)),
            ("mail-workspace-search", AnyView(workspace(search: true)), NSSize(width: 1140, height: 700)),
            ("mail-add-account", AnyView(AddMailAccountSheet(demo: true)), NSSize(width: 520, height: 640))
        ]
    }

    /// Mail fixtures only, without starting a launcher session or reading desktop context.
    static func writeAll(to directory: String) {
        let shots = windows
        func render(_ index: Int) {
            guard index < shots.count else { NSApp.terminate(nil); return }
            let (name, view, size) = shots[index]
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView: view)
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let content = window.contentView {
                    UISnapshots.write(content, name: name, to: directory)
                    print("[Jev snapshot] \(name) content=\(Int(content.bounds.width))x\(Int(content.bounds.height))")
                    fflush(stdout)
                }
                window.orderOut(nil)
                render(index + 1)
            }
        }
        render(0)
    }

    static func composer() -> some View {
        let model = fixture()
        model.draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                      mode: .new, to: "sam@example.com", subject: "Friday's Plan", body: "Hi Sam,\n\nFriday at 10 works for me. I have attached the agenda.\n\nAlex")
        model.draft?.attachments = [.init(filename: "Agenda.pdf", mimeType: "application/pdf", data: Data(repeating: 0, count: 2048))]
        return ComposeView(model: model)
    }

    /// A reply to an invented HTML newsletter, with its quote below the text, as it is sent.
    static func reply() -> some View {
        let model = fixture()
        let raw = """
        From: Bodhi <bodhi@example.com>\r
        To: alex@example.com\r
        Subject: Stop Letting Leads Die\r
        Message-ID: <demo-1@example.com>\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><head><style>.card{background:#f0f0f0;border-radius:12px;padding:20px;font-family:Helvetica}h1{font-size:28px}</style></head>
        <body><div class="card"><h1>Stop Letting Leads Die</h1><p>Someone leaves your website without calling? Keep marketing to them.</p>
        <p>This is why retargeting works for home service businesses.</p></div></body></html>\r
        """
        let message = MIMEMessage.parse(Data(raw.utf8))!
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 3, minute: 1)) ?? Date()
        let original = MailSummary(rowID: 1, mailbox: 1, subject: "Stop Letting Leads Die", senderName: "Bodhi", senderAddress: "bodhi@example.com",
                                   snippet: "", date: date, read: true, flagged: false, conversation: 0)
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                    mode: .reply(all: false), subject: "Re: Stop Letting Leads Die", body: "Thanks Bodhi, this is useful.",
                                    original: original, source: .init(rowID: 1, message: message, html: message.html))
        draft.ownAddresses = ["alex@example.com"]
        draft.fillRecipients()
        model.draft = draft
        return ComposeView(model: model)
    }

    static func outbox() -> some View {
        let model = fixture()
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                    mode: .new, to: "sam@example.com", subject: "Friday's Plan", body: "Friday at 10 works.")
        draft.uncertainSend = true
        model.deliveries = [.init(id: draft.id, draft: draft, subject: draft.subject, recipient: draft.to, date: Date(), state: .uncertain,
                                 note: "The server may have accepted this message. Check Sent before resending.")]
        return MailDeliveryView(model: model)
    }

    static func workspace(compact: Bool = false, drafts: Bool = false, search: Bool = false) -> some View {
        let model = fixture()
        let roles: [MailMailbox.Role] = [.inbox, .drafts, .sent, .archive, .junk, .trash, .other, .other]
        let names = ["INBOX", "Drafts", "Sent", "Archive", "Junk", "Trash", "Clients", "Clients/Acme"]
        let boxes = names.enumerated().map { offset, name in
            MailMailbox(rowID: Int64(offset + 1), url: "imap://demo/" + name, unread: offset == 0 ? 12 : offset == 7 ? 3 : 0,
                        total: offset == 0 ? 500 : 20, serverRole: roles[offset],
                        serverTotal: offset == 0 ? 18_240 : 240, syncComplete: false, initialized: offset != 7)
        } + [MailMailbox(rowID: 20, url: "imap://personal/INBOX", unread: 2, total: 25, serverRole: .inbox)]
        let subjects = ["Friday's Plan", "Design Review", "October Invoice", "Launch Checklist", "Project Update", "Catch Up Next Week"]
        let people = ["Sam Lee", "Jamie Park", "Accounts", "Alex Chen", "Morgan Riley", "Casey"]
        let messages = subjects.enumerated().map { offset, subject in
            MailSummary(rowID: Int64(offset + 1), mailbox: 1, subject: subject, senderName: people[offset],
                        senderAddress: "sender\(offset)@example.com", snippet: "", date: Date().addingTimeInterval(Double(-offset * 3600)),
                        read: offset > 1, flagged: offset == 1, conversation: 0)
        }
        var message = OutgoingMessage(from: .init(name: "Sam Lee", address: "sam@example.com"), to: [.init(address: "alex@example.com")],
                                      subject: "Friday's Plan", body: "Hi Alex,\n\nFriday at 10 works well. Please find the agenda attached.\n\nSee you then,\nSam")
        message.attachments = [.init(filename: "Agenda.pdf", mimeType: "application/pdf", data: Data(repeating: 0, count: 2048))]
        let detail = MIMEMessage.parse(MailComposer.render(message))
        model.installDemo(mailboxes: boxes, messages: drafts ? [] : search ? messages.filter { $0.subject.contains("Friday") } : messages, detail: detail)
        model.favoriteMailboxKeys = [boxes[7].url]
        model.senders.append(.init(accountID: "personal", address: "alex@personal.example", name: "Alex", signature: ""))
        if drafts {
            model.place = .drafts
            model.draft = .init(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                to: "sam@example.com", subject: "Friday's Plan", body: "Hi Sam,\n\nFriday at 10 works for me.\n\nAlex")
        }
        if search {
            model.searching = true; model.search = "Friday"; model.searchScope = .allAccounts
            model.serverSearch = .more
        }
        return MailRootView(model: model, showsSidebar: !compact)
    }

    private static func fixture() -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, statusProvider: { .noMail },
                              setRead: { _, _, _, _ in throw CancellationError() }, sendDraft: { _, _ in throw CancellationError() }, draftStore: nil)
        model.senders = [.init(accountID: "demo", address: "alex@example.com", name: "Alex Morgan", signature: "Alex Morgan")]
        return model
    }
}
