import AppKit
import LauncherCore
import SwiftUI

/// Invented composition state only. No store, account, credential, or send path is used.
@MainActor
enum MailSnapshots {
    static var windows: [(String, AnyView, NSSize)] {
        [
            ("mail-compose", AnyView(composer()), NSSize(width: 640, height: 520)),
            ("mail-compose-formatting", AnyView(composerFormatting()), NSSize(width: 820, height: 560)),
            panel("mail-draft-signin-blocked", blockedDraft(signInRefused: true)),
            panel("mail-draft-review-blocked", blockedDraft(signInRefused: false)),
            ("mail-reply", AnyView(reply()), NSSize(width: 820, height: 760)),
            panel("mail-outbox", outbox()),
            panel("mail-outbox-history", outbox(review: false), width: 980),
            panel("mail-workspace", statusPage(workspace())),
            panel("mail-workspace-attention", statusPage(workspace(), attention: true), width: 980),
            panel("mail-workspace-columns", customColumns()),
            panel("mail-workspace-columns-smallest", customColumns(), width: 860),
            panel("mail-invitation", MailPage(mail: workspace(invitation: true))),
            panel("mail-thread", thread()),
            panel("mail-thread-compact", thread(), width: 980),
            panel("mail-thread-smallest", thread(), width: 860),
            panel("mail-thread-light", thread(), width: 980),
            panel("mail-designed", MailPage(mail: workspace(designed: true))),
            panel("mail-designed-light", MailPage(mail: workspace(designed: true)), width: 980),
            panel("mail-designed-smallest", MailPage(mail: workspace(designed: true)), width: 860),
            panel("mail-designed-dark-page", MailPage(mail: workspace(designed: true, darkPage: true)), width: 980),
            panel("mail-designed-dark-page-light", MailPage(mail: workspace(designed: true, darkPage: true)), width: 980),
            panel("mail-simple-html", simpleHTML(), width: 980),
            panel("mail-simple-html-light", simpleHTML(), width: 980),
            panel("mail-loading", reading(holds: true)),
            panel("mail-not-downloaded", reading(holds: false), width: 980),
            panel("mail-keyboard-selection", keyboardSelection()),
            panel("mail-workspace-light", statusPage(workspace())),
            panel("mail-workspace-folders-expanded", MailPage(mail: workspace(providerFoldersExpanded: true))),
            panel("mail-workspace-compact", statusPage(workspace()), width: 980),
            panel("mail-workspace-smallest", statusPage(workspace()), width: 860),
            panel("mail-workspace-drafts-compact", statusPage(workspace(drafts: true)), width: 980),
            panel("mail-workspace-drafts-smallest", statusPage(workspace(drafts: true)), width: 860),
            panel("mail-workspace-sidebar-hidden", sidebarHidden(), width: 980),
            panel("mail-workspace-drafts", statusPage(workspace(drafts: true))),
            panel("mail-workspace-search", MailPage(mail: workspace(search: true))),
            panel("mail-workspace-search-light", MailPage(mail: workspace(search: true)), width: 980),
            panel("mail-workspace-accounts", MailPage(mail: longList())),
            panel("mail-workspace-accounts-light", MailPage(mail: longList()), width: 980),
            panel("mail-workspace-bulk", MailPage(mail: bulkSelection())),
            panel("mail-workspace-bulk-light", MailPage(mail: bulkSelection()), width: 980),
            panel("mail-workspace-bulk-smallest", MailPage(mail: bulkSelection()), width: 860),
            panel("mail-workspace-hover", MailPage(mail: longList()), hover: 3),
            panel("mail-workspace-hover-light", MailPage(mail: longList()), width: 980, hover: 3),
            panel("mail-workspace-filters", MailPage(mail: filtered())),
            panel("mail-workspace-filters-light", MailPage(mail: filtered()), width: 980),
            panel("mail-workspace-filters-smallest", MailPage(mail: filtered()), width: 860),
            panel("mail-undo-note", undoNote()),
            panel("mail-draft-saved", draftSaved()),
            ("mail-snooze-presets", AnyView(snoozeEditor()), NSSize(width: 340, height: 330)),
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
    /// `hover` shows that row's buttons as if the pointer were on it.
    static func panel(_ name: String, _ page: MailPage, width: CGFloat = 1320, hover: Int64? = nil) -> (String, AnyView, NSSize) {
        let size = NSSize(width: width, height: 880 - LauncherMetrics.searchBarHeight)
        let view = VStack(spacing: 0) {
            Divider()
            page.content().frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.mailRowHoverPreview, hover)
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
            if name.hasSuffix("-light") { window.appearance = NSAppearance(named: .aqua) }
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

    /// A new message started as ⌘N starts it, with the account's signature below the text and the
    /// formatting bar shown with Aa.
    static func composerFormatting() -> some View {
        let model = fixture()
        model.startDraft(MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                         mode: .new, to: "sam@example.com", subject: "Friday's Plan",
                                         body: "Hi Sam,\n\nFriday at 10 works for me.", signsAutomatically: true))
        return ComposeView(model: model, preferences: MailComposerPreferences(defaults: nil, showsFormatting: true))
    }

    /// Two invented accounts with a sync state, Mail Settings, and the status line at the bottom
    /// of the sidebar. With `attention`, the second account needs to sign in again.
    static func statusPage(_ model: MailModel, attention: Bool = false) -> MailPage {
        var account = NativeMailAccount.preset(.gmail, name: "Alex Morgan", email: "alex@example.com")!
        account.id = "demo"
        var personal = NativeMailAccount.preset(.gmail, name: "Alex", email: "alex@gmail.com")!
        personal.id = "personal"
        let center = NativeMailCenter(backend: .jevcast, accounts: [account, personal], defaults: nil)
        center.showDemoState(account.id, .ready(Date().addingTimeInterval(-130)))
        center.showDemoState(personal.id, attention ? .failed("This account needs you to sign in again.", signIn: true)
                                                    : .ready(Date().addingTimeInterval(-400)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-demo-" + UUID().uuidString)
        let features = MailFeatureCenter(directory: directory, defaults: nil, accounts: [account, personal])
        return MailPage(mail: model, accountCenter: center, features: features)
    }

    /// Columns dragged wider: a 250-point sidebar and a 470-point list, clamped at small panels.
    static func customColumns() -> MailPage {
        let page = statusPage(workspace())
        page.dragSidebar(to: 250)
        page.dragList(to: 470, split: MailReading.split)
        return page
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

    /// Outbox with a send that may have gone, or (`review: false`) with sent history only, which
    /// needs no note.
    static func outbox(review: Bool = true) -> MailPage {
        let model = workspace()
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                    mode: .new, to: "sam@example.com", subject: "Friday's Plan", body: "Friday at 10 works.")
        draft.uncertainSend = review
        model.deliveries = review
            ? [.init(id: draft.id, draft: draft, subject: draft.subject, recipient: draft.to, date: Date(), state: .uncertain,
                     note: "The server may have accepted this message. Check Sent before resending.")]
            : [.init(id: draft.id, draft: nil, subject: draft.subject, recipient: draft.to, date: Date(), state: .sent, note: nil)]
        model.place = .outbox
        return statusPage(model)
    }

    /// The Undo note of a Delete All from a sender, with another note above it: both show.
    static func undoNote() -> MailPage {
        let model = workspace()
        model.lastChange = MailUndoableChange(id: UUID(), operation: .trash, title: "Moved 12 messages from Sam Lee to Trash")
        model.banner = "Checking for new mail…"
        return MailPage(mail: model)
    }

    /// A draft closed with Escape: the composer steps aside and a note offers to open it again.
    static func draftSaved() -> MailPage {
        let model = workspace()
        model.draft = .init(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                            to: "sam@example.com", subject: "Friday's Plan", body: "Hi Sam,\n\nFriday at 10 works for me.\n\nAlex")
        let page = MailPage(mail: model)
        _ = page.back()
        return page
    }

    /// Snooze with its one-click times above the date picker. Nothing is saved.
    static func snoozeEditor() -> some View {
        let model = workspace()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-demo-" + UUID().uuidString)
        let center = MailSnoozeCenter(store: MailSnoozeStore(directory: directory))
        return MailSnoozeEditor(message: model.messages[0], account: .init(accountID: "demo", address: "alex@example.com"), messageID: nil,
                                center: center, initialDate: Date().addingTimeInterval(3600))
    }

    static func sidebarHidden() -> MailPage {
        let page = statusPage(workspace())
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
    static func workspace(drafts: Bool = false, search: Bool = false, providerFoldersExpanded: Bool = false, invitation: Bool = false,
                          designed: Bool = false, darkPage: Bool = false) -> MailModel {
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
        let previews = ["Friday at 10 works well. Please find the agenda attached.", "You are invited to the design review on Thursday.",
                        "Your invoice for October is ready to view.", "Two items are left before we can ship.",
                        "The first phase is complete. Here is what comes next.", "Are you free for a call on Tuesday?"]
        var messages = subjects.enumerated().map { offset, subject in
            MailSummary(rowID: Int64(offset + 1), mailbox: offset == 4 ? 20 : 1, subject: subject, senderName: people[offset],
                        senderAddress: "sender\(offset)@example.com", snippet: previews[offset], date: Date().addingTimeInterval(Double(-offset * 3600)),
                        read: offset > 1, flagged: offset == 1, conversation: Int64(offset + 1))
        }
        // The invitation fixture opens on the invitation.
        if invitation { messages.swapAt(0, 1) }
        var message = OutgoingMessage(from: .init(name: "Sam Lee", address: "sam@example.com"), to: [.init(address: "alex@example.com")],
                                      subject: "Friday's Plan", body: "Hi Alex,\n\nFriday at 10 works well. Please find the agenda attached.\n\nSee you then,\nSam")
        message.attachments = [.init(filename: "Agenda.pdf", mimeType: "application/pdf", data: Data(repeating: 0, count: 2048))]
        var detail = MIMEMessage.parse(MailComposer.render(message))
        if invitation { detail = MIMEMessage.parse(Data(invitationMessage().utf8)) }
        if designed {
            // A newsletter with its own page colours, from a list that says how to leave it.
            messages[0] = MailSummary(rowID: 1, mailbox: 1, subject: "The Autumn Collection Is Here", senderName: "Northwind Studio",
                                      senderAddress: "news@northwind.example", snippet: "New colours for the cooler months.",
                                      date: Date().addingTimeInterval(-600), read: false, flagged: false, conversation: 1)
            detail = MIMEMessage.parse(Data((darkPage ? darkPageMessage() : designedMessage()).utf8))
        }
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

    /// Twelve invented conversations of two accounts, from today back to last year, so the list
    /// shows its date labels and each account's colour.
    static func longList() -> MailModel {
        let model = workspace()
        let calendar = Calendar.current
        let now = Date()
        let people = ["Sam Lee", "Jamie Park", "Accounts", "Alex Chen", "Morgan Riley", "Casey", "Priya Shah", "Studio Team",
                      "Taylor Brooks", "Northwind Studio", "Jordan Hale", "Robin Ellis"]
        let subjects = ["Friday's Plan", "Design Review", "October Invoice", "Launch Checklist", "Project Update", "Catch Up Next Week",
                        "Photos from the Workshop", "Office Closed on Monday", "Contract Draft", "The Autumn Collection Is Here",
                        "Quarterly Numbers", "Welcome Aboard"]
        let previews = ["Friday at 10 works well. Please find the agenda attached.", "You are invited to the design review on Thursday.",
                        "Your invoice for October is ready to view.", "Two items are left before we can ship.",
                        "The first phase is complete. Here is what comes next.", "Are you free for a call on Tuesday?",
                        "I have put the photos in the shared folder.", "The office is closed on Monday for maintenance.",
                        "Here is the contract draft with the changes we agreed.", "New colours for the cooler months.",
                        "The numbers for the quarter are in the attached sheet.", "We are glad to have you with us."]
        let daysAgo = [0, 0, 0, 1, 1, 2, 3, 8, 9, 40, 70, 400]
        let messages = people.indices.map { index in
            let day = calendar.date(byAdding: .day, value: -daysAgo[index], to: now) ?? now
            return MailSummary(rowID: Int64(index + 1), mailbox: index % 3 == 1 ? 20 : 1, subject: subjects[index], senderName: people[index],
                               senderAddress: "sender\(index)@example.com", snippet: previews[index],
                               date: day.addingTimeInterval(Double(-index * 600)), read: index > 2 && index != 5,
                               flagged: index == 1, conversation: Int64(index + 1))
        }
        model.messages = messages
        return model
    }

    /// Three conversations of one account selected: the bar below the list offers what they can all do.
    static func bulkSelection() -> MailModel {
        let model = longList()
        model.selectConversationRows([1, 3, 4])
        return model
    }

    /// Unread on with a sender filter from the form: the chip is on, "+1" counts the other filter.
    static func filtered() -> MailModel {
        let model = workspace()
        model.messages = model.messages.filter { !$0.read }
        model.filter = MailFilter(from: "sender", unreadOnly: true)
        return model
    }

    /// An invented invitation, as a calendar server sends it: text for people and iCalendar for programs.
    static func invitationMessage() -> String {
        let day = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
        let stamp = day.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        let calendar = ["BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:REQUEST", "BEGIN:VEVENT", "UID:demo-design-review@example.com", "SEQUENCE:0",
                        "DTSTART:\(stamp)T100000", "DTEND:\(stamp)T104500", "SUMMARY:Design Review", "LOCATION:Studio, Room 4",
                        "ORGANIZER;CN=Jamie Park:mailto:jamie@example.com", "ATTENDEE;CN=Alex Morgan;PARTSTAT=NEEDS-ACTION:mailto:alex@example.com",
                        "ATTENDEE;CN=Sam Lee;PARTSTAT=ACCEPTED:mailto:sam@example.com", "END:VEVENT", "END:VCALENDAR"].joined(separator: "\r\n")
        return "From: Jamie Park <jamie@example.com>\r\nTo: alex@example.com\r\nSubject: Design Review\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: multipart/alternative; boundary=\"demo\"\r\n\r\n--demo\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
            + "Hi Alex,\n\nYou are invited to the design review on Thursday. We will look at the new onboarding screens.\n\nJamie\r\n"
            + "--demo\r\nContent-Type: text/calendar; method=REQUEST; charset=utf-8\r\n\r\n" + calendar + "\r\n--demo--\r\n"
    }

    /// An invented newsletter: a table layout on a tinted page, as a designed message arrives.
    static func designedMessage() -> String {
        let html = "<html><head><style>.wrap{width:560px;margin:0 auto;background:#ffffff;border-radius:6px}"
            + "h1{font:600 26px Georgia,serif;color:#1f2a44;margin:0 0 8px}p{font:15px/1.5 Helvetica,sans-serif;color:#3c4458}"
            + ".band{background:#1f2a44;color:#f5efe6;font:600 13px Helvetica,sans-serif;letter-spacing:2px;padding:14px 24px}"
            + ".button{display:inline-block;background:#c8553d;color:#ffffff;padding:10px 18px;border-radius:4px;text-decoration:none;font:600 14px Helvetica,sans-serif}"
            + "</style></head><body bgcolor=\"#f1ece4\"><table class=\"wrap\" cellpadding=\"0\" cellspacing=\"0\">"
            + "<tr><td class=\"band\">NORTHWIND STUDIO</td></tr><tr><td style=\"padding:28px 24px\">"
            + "<h1>The Autumn Collection Is Here</h1><p>New colours for the cooler months: rust, slate, and a warm oat that goes with everything.</p>"
            + "<p>Members see it first, until Sunday.</p><p><a class=\"button\" href=\"https://northwind.example/autumn\">See the collection</a></p>"
            + "</td></tr><tr><td style=\"padding:16px 24px;font:12px Helvetica,sans-serif;color:#8a8f9c\">You receive this because you joined our list.</td></tr>"
            + "</table></body></html>"
        return "From: Northwind Studio <news@northwind.example>\r\nTo: alex@example.com\r\nSubject: The Autumn Collection Is Here\r\n"
            + "List-Unsubscribe: <https://northwind.example/unsubscribe>\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n\r\n" + html + "\r\n"
    }

    /// An invented designed message that sets a dark page with light text on its root element.
    /// The reader must keep both, so the text stays readable.
    static func darkPageMessage() -> String {
        let html = "<html style=\"background:#14171f;color:#e9e4da\"><head><style>h1{font:600 26px Georgia,serif;margin:0 0 8px}"
            + "p{font:15px/1.5 Helvetica,sans-serif}a{color:#f0a868}</style></head><body><table cellpadding=\"0\" cellspacing=\"0\">"
            + "<tr><td style=\"padding:28px 24px\"><h1>The Autumn Collection Is Here</h1>"
            + "<p>New colours for the cooler months: rust, slate, and a warm oat that goes with everything.</p>"
            + "<p><a href=\"https://northwind.example/autumn\">See the collection</a></p></td></tr></table></body></html>"
        return "From: Northwind Studio <news@northwind.example>\r\nTo: alex@example.com\r\nSubject: The Autumn Collection Is Here\r\n"
            + "MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\n\r\n" + html + "\r\n"
    }

    /// A message of HTML that is only text, as most personal mail is: it sits on the pane's surface.
    static func simpleHTML() -> MailPage {
        let model = workspace()
        let raw = "From: Sam Lee <sam@example.com>\r\nTo: alex@example.com\r\nCc: jamie@example.com\r\nSubject: Friday's Plan\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n\r\n<div dir=\"ltr\">Hi Alex,<br><br>Friday at 10 works well. "
            + "The agenda is <a href=\"https://example.com/agenda\">on the shared drive</a>.<br><br><b>See you then,</b><br>Sam</div>\r\n"
        if let detail = MIMEMessage.parse(Data(raw.utf8)) { model.installDemoBody(detail, rowID: 1) }
        model.select(2, byUser: false)
        model.select(1, byUser: true)
        return MailPage(mail: model)
    }

    /// The reader on a message whose body is not on this Mac: still loading, or not downloaded.
    static func reading(holds: Bool) -> MailPage {
        let model = workspace()
        model.demoHoldsBodies = holds
        model.select(3, byUser: true)
        return MailPage(mail: model)
    }

    static func thread() -> MailPage {
        let model = workspace()
        let first = model.messages[0]
        let replies = (0..<4).map { offset in
            MailSummary(rowID: Int64(100 + offset), mailbox: 1, subject: "Re: Friday's Plan",
                senderName: offset % 2 == 0 ? "Sam Lee" : "Alex Morgan", senderAddress: offset % 2 == 0 ? "sam@example.com" : "alex@example.com",
                snippet: ["Confirmed. See you Friday at 10!", "Thanks Sam. Could we start at 10?", "Friday works. Shall we meet at the studio?",
                          "Are you free to review the designs this week?"][offset],
                date: first.date.addingTimeInterval(Double(-offset * 3600)), read: offset > 0,
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
