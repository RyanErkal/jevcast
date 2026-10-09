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
            panel("mail-thread", thread()),
            panel("mail-thread-compact", thread(), width: 980),
            panel("mail-thread-smallest", thread(), width: 860),
            panel("mail-keyboard-selection", keyboardSelection()),
            panel("mail-workspace-light", MailPage(mail: workspace())),
            panel("mail-workspace-folders-expanded", MailPage(mail: workspace(providerFoldersExpanded: true))),
            panel("mail-workspace-compact", MailPage(mail: workspace()), width: 980),
            panel("mail-workspace-drafts-compact", MailPage(mail: workspace(drafts: true)), width: 980),
            panel("mail-workspace-drafts-smallest", MailPage(mail: workspace(drafts: true)), width: 860),
            panel("mail-workspace-sidebar-hidden", sidebarHidden(), width: 980),
            panel("mail-workspace-drafts", MailPage(mail: workspace(drafts: true))),
            panel("mail-workspace-search", MailPage(mail: workspace(search: true))),
            panel("mail-account-signin", accountConnection(signIn: true), width: 980),
            panel("mail-account-retry", accountConnection(signIn: false), width: 980),
            panel("mail-account-password", accountConnection(signIn: true, password: true), width: 980),
            ("mail-add-account", AnyView(AddMailAccountSheet(demo: true)), NSSize(width: 520, height: 640))
        ] + toolWindows
    }

    static var toolWindows: [(String, AnyView, NSSize)] {
        MailTool.allCases.flatMap { tool in
            [panel("mail-tools-" + String(describing: tool), toolPage(tool)),
             panel("mail-tools-" + String(describing: tool) + "-compact", toolPage(tool), width: 860)]
        } + [panel("mail-compose-scheduled", toolPage(nil, composing: true), width: 980)]
    }

    static func toolPage(_ tool: MailTool?, composing: Bool = false) -> MailPage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-demo-" + UUID().uuidString)
        var account = NativeMailAccount.preset(.gmail, name: "Alex Morgan", email: "alex@example.com")!
        account.id = "demo"
        let features = MailFeatureCenter(directory: directory, defaults: nil, accounts: [account])
        let model = workspace(drafts: composing)
        let native = NativeMailCenter(backend: .jevcast, accounts: [account], defaults: nil)
        let page = MailPage(mail: model, accountCenter: native, features: features)
        if tool == .rules {
            features.rules.save(.init(name: "Flag client updates", predicate: .init(from: "client@example.com"), actions: [.markFlagged(true)]))
        }
        if tool == .smart {
            features.smart.saveMailbox(.init(name: "Client updates", predicate: .init(subject: "Update")))
            features.smart.setVIP("sam@example.com", enabled: true)
        }
        if tool == .snoozed, let message = model.messages.first {
            _ = try? features.snoozes.snooze(message: message, account: .init(account), messageID: "<demo@example.com>", until: Date().addingTimeInterval(3600))
        }
        if tool == .scheduled {
            let draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: account.id,
                fromAddress: account.email, mode: .new, to: "sam@example.com", subject: "Friday's Plan", body: "Friday at 10 works. See you then.")
            _ = try? features.schedules.schedule(draft, account: .init(account), at: Date().addingTimeInterval(3600))
        }
        if tool == .archive {
            let source = directory.appendingPathComponent("example.eml")
            let raw = "From: Sam <sam@example.com>\r\nTo: alex@example.com\r\nSubject: Archived project notes\r\nDate: Fri, 9 Oct 2026 09:00:00 +0100\r\nMessage-ID: <archive-demo@example.com>\r\n\r\nThe project notes are ready for review.\r\n"
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data(raw.utf8).write(to: source)
            if let archive = try? features.archive() { _ = try? archive.importArchive(url: source) }
        }
        page.tool = tool
        return page
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

    static func accountConnection(signIn: Bool, password: Bool = false) -> MailPage {
        var account = NativeMailAccount.preset(password ? .yahoo : .gmail, name: "Alex Morgan", email: "alex@example.com")!
        account.id = "demo"; account.authentication = password ? .password : .oauth
        var personal = NativeMailAccount.preset(.gmail, name: "Alex", email: "alex@gmail.com")!
        personal.id = "personal"; personal.authentication = .oauth
        var pending = personal; pending.id = "new-account"; pending.email = "alex@new.example"
        let center = NativeMailCenter(backend: .jevcast, accounts: [account, personal, pending], defaults: nil)
        center.recordState(account.id, .ready(Date(timeIntervalSince1970: 1_791_532_800)))
        center.recordState(account.id, .failed(signIn ? "This account needs you to sign in again." : "The mail provider is temporarily unavailable.", signIn: signIn))
        center.recordState(personal.id, .ready(Date(timeIntervalSince1970: 1_791_532_800)))
        center.recordState(pending.id, .failed("No saved sign-in was found for this account.", signIn: true))
        let page = MailPage(mail: workspace(), accountCenter: center)
        page.accountDetailsID = account.id
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
                        read: offset > 1, flagged: offset == 1, conversation: Int64(offset + 1))
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

    static func thread() -> MailPage {
        let model = workspace()
        let first = model.messages[0]
        let replies = (0..<4).map { offset in
            MailSummary(rowID: Int64(100 + offset), mailbox: 1, subject: "Re: Friday's Plan",
                senderName: offset % 2 == 0 ? "Sam Lee" : "Alex Morgan", senderAddress: offset % 2 == 0 ? "sam@example.com" : "alex@example.com",
                snippet: "", date: first.date.addingTimeInterval(Double(-offset * 3600)), read: offset > 0,
                flagged: false, conversation: 900)
        }
        model.messages = replies + model.messages.dropFirst()
        for (index, message) in replies.enumerated() {
            let text = ["Confirmed. See you Friday at 10!", "Thanks Sam. Could we start at 10?", "Friday works. Shall we meet at the studio?", "Are you free to review the designs this week?"][index]
            let raw = "From: \(message.senderAddress)\r\nTo: alex@example.com\r\nSubject: Friday's Plan\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>" + text + "</p><div class=\"gmail_quote\">On Thursday, someone wrote:<blockquote>Earlier message repeated here.</blockquote></div>"
            if let detail = MIMEMessage.parse(Data(raw.utf8)) { model.installDemoBody(detail, rowID: message.rowID) }
        }
        model.select(replies[0].rowID, byUser: true)
        var account = NativeMailAccount.preset(.gmail, name: "Alex", email: "alex@example.com")!
        account.id = "demo"
        let center = NativeMailCenter(backend: .jevcast, accounts: [account], defaults: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-demo-" + UUID().uuidString)
        let features = MailFeatureCenter(directory: directory, defaults: nil, accounts: [account])
        return MailPage(mail: model, accountCenter: center, features: features)
    }

    static func keyboardSelection() -> MailPage {
        let page = thread()
        page.mail?.moveSelection(1)
        return page
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
