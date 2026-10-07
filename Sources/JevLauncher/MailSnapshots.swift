import AppKit
import LauncherCore
import SwiftUI

/// Invented composition state only. No store, account, credential, or send path is used.
@MainActor
enum MailSnapshots {
    static var windows: [(String, AnyView, NSSize)] {
        [
            ("mail-compose", AnyView(composer()), NSSize(width: 640, height: 520)),
            panel("mail-draft-signin-blocked", blockedDraft(signInRefused: true)),
            panel("mail-draft-review-blocked", blockedDraft(signInRefused: false)),
            ("mail-reply", AnyView(reply()), NSSize(width: 820, height: 760)),
            panel("mail-outbox", outbox()),
            panel("mail-workspace", MailPage(mail: workspace())),
            panel("mail-workspace-light", MailPage(mail: workspace())),
            panel("mail-workspace-folders-expanded", MailPage(mail: workspace(providerFoldersExpanded: true))),
            panel("mail-workspace-compact", MailPage(mail: workspace()), width: 980),
            panel("mail-workspace-drafts-compact", MailPage(mail: workspace(drafts: true)), width: 980),
            panel("mail-workspace-drafts-smallest", MailPage(mail: workspace(drafts: true)), width: 860),
            panel("mail-workspace-sidebar-hidden", sidebarHidden(), width: 980),
            panel("mail-workspace-drafts", MailPage(mail: workspace(drafts: true))),
            panel("mail-workspace-search", MailPage(mail: workspace(search: true))),
            ("mail-add-account", AnyView(AddMailAccountSheet(demo: true)), NSSize(width: 520, height: 640))
        ]
    }

    /// The panel's Mail view as the launcher shows it below the search field: the page's own
    /// content and footer, at the largest view size or a smaller panel's width.
    static func panel(_ name: String, _ page: MailPage, width: CGFloat = 1320) -> (String, AnyView, NSSize) {
        let size = NSSize(width: width, height: 880 - LauncherMetrics.searchBarHeight)
        let view = VStack(spacing: 0) {
            Divider()
            page.content().frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PageFooter(page: page, escapeClosesLauncher: false)
        }
        .frame(width: size.width, height: size.height)
        return (name, AnyView(view), size)
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
            if name == "mail-workspace-light" { window.appearance = NSAppearance(named: .aqua) }
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

    static func outbox() -> MailPage {
        let model = workspace()
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                    mode: .new, to: "sam@example.com", subject: "Friday's Plan", body: "Friday at 10 works.")
        draft.uncertainSend = true
        model.deliveries = [.init(id: draft.id, draft: draft, subject: draft.subject, recipient: draft.to, date: Date(), state: .uncertain,
                                 note: "The server may have accepted this message. Check Sent before resending.")]
        model.place = .outbox
        return MailPage(mail: model)
    }

    static func sidebarHidden() -> MailPage {
        let page = MailPage(mail: workspace())
        page.showsSidebar = false
        return page
    }

    /// Invented accounts, folders, and messages, ready as the panel shows them. The first message is selected.
    static func workspace(drafts: Bool = false, search: Bool = false, providerFoldersExpanded: Bool = false) -> MailModel {
        let model = fixture()
        let roles: [MailMailbox.Role] = [.inbox, .drafts, .sent, .archive, .junk, .trash, .other, .other, .other, .other]
        let names = ["INBOX", "[Gmail]/Drafts", "[Gmail]/Sent Mail", "[Gmail]/All Mail", "[Gmail]/Spam", "[Gmail]/Trash",
                     "Clients", "Clients/Acme", "[Gmail]/Important", "[Gmail]/Starred"]
        let boxes = names.enumerated().map { offset, name in
            MailMailbox(rowID: Int64(offset + 1), url: "imap://demo/" + name, unread: offset == 0 ? 12 : offset == 7 ? 3 : 0,
                        total: offset == 0 ? 500 : 20, serverRole: roles[offset],
                        serverTotal: offset == 0 ? 48_240 : offset == 1 ? 3 : offset == 5 ? 6 : 240,
                        serverUnread: offset == 0 ? 33_007 : nil, syncComplete: false, initialized: offset != 7)
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
        if providerFoldersExpanded { model.expandedSidebarGroupKeys = ["demo:[Gmail]"] }
        model.senders.append(.init(accountID: "personal", address: "alex@gmail.com", name: "Alex", signature: ""))
        if drafts {
            model.place = .drafts
            model.draft = .init(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                to: "sam@example.com", subject: "Friday's Plan", body: "Hi Sam,\n\nFriday at 10 works for me.\n\nAlex")
        }
        if search {
            // The launcher's field sets the search; the list shows where it looks.
            model.search = "Friday"; model.searchScope = .allAccounts
            model.serverSearch = .more
        }
        return model
    }

    /// A draft whose server copy is blocked, open in the panel beside the list.
    static func blockedDraft(signInRefused: Bool) -> MailPage {
        let model = workspace()
        model.serverDrafts = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in throw CancellationError() },
                                                       remove: { _ in throw CancellationError() })
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                    to: "sam@example.com", subject: "Friday's Plan", body: "Hi Sam,\n\nFriday at 10 works for me.\n\nAlex")
        draft.serverDraftBlockedReason = signInRefused
            ? "The mail server refused this account's sign-in. Fix the account in Settings › Mail."
            : "The server may have saved this draft, but its acknowledgement was lost. Review Drafts before trying again."
        draft.serverDraftBlockKind = signInRefused ? .signInRefused : nil
        draft.serverDraftAcknowledgementUncertain = signInRefused ? nil : true
        model.draft = draft
        return MailPage(mail: model)
    }

    private static func fixture() -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, statusProvider: { .noMail },
                              setRead: { _, _, _, _ in throw CancellationError() }, sendDraft: { _, _ in throw CancellationError() }, draftStore: nil)
        model.senders = [.init(accountID: "demo", address: "alex@example.com", name: "Alex Morgan", signature: "Alex Morgan")]
        // No cleanup file and no server: the default coordinator reads the real composition folder.
        model.serverDrafts = MailServerDraftCoordinator(model: model, save: nil, remove: nil, cleanupStore: nil)
        return model
    }
}
