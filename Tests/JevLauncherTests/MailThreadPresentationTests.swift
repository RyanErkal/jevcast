import XCTest
import SwiftUI
import WebKit
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailThreadPresentationTests: XCTestCase {
    func testKeyboardMovesBetweenVisibleThreadsAndKeepsSelectionHighlighted() throws {
        let page = MailSnapshots.thread()
        let model = try XCTUnwrap(page.mail)
        XCTAssertEqual(model.selectedConversation?.messages.count, 4)
        XCTAssertEqual(model.selectedConversationRowID, 100)
        XCTAssertTrue(page.handle(.down))
        XCTAssertEqual(model.selectedID, 2)
        XCTAssertEqual(model.selectedMessageIDs, [2])
        XCTAssertEqual(model.selectedConversationRowIDs, [2])
        XCTAssertTrue(page.handle(.up))
        XCTAssertEqual(model.selectedID, 100)
        XCTAssertEqual(model.selectedMessageIDs, [100])
        model.select(102, byUser: true)
        XCTAssertEqual(model.selectedConversationRowID, 100, "An older reply keeps its one conversation row highlighted.")
        model.moveSelection(1)
        XCTAssertEqual(model.selectedID, 2, "Arrow navigation follows the visible list, not hidden thread members.")
    }

    func testBulkConversationSelectionIncludesMembersWithoutAffectingOtherThreads() throws {
        let model = try XCTUnwrap(MailSnapshots.thread().mail)
        model.selectConversationRows([100, 2])
        XCTAssertEqual(model.selectedMessageIDs, [100, 101, 102, 103, 2])
        XCTAssertEqual(model.selectedConversationRowIDs, [100, 2])
        model.moveSelection(1)
        XCTAssertEqual(model.selectedMessageIDs.count, 1, "Normal arrow navigation leaves bulk selection.")
    }

    func testReadingThreadBodiesDoesNotMoveSelectionOrMarkOtherRepliesRead() async throws {
        let model = try XCTUnwrap(MailSnapshots.thread().mail)
        let selection = model.selectedID
        let before = model.messages
        for message in model.selectedConversation!.messages {
            let body = await model.conversationBody(message.summary)
            XCTAssertNotNil(body)
        }
        XCTAssertEqual(model.selectedID, selection)
        XCTAssertEqual(model.messages, before)
    }

    func testThreadRendersRepliesTogetherAndCanRevealQuotedText() async throws {
        try skipLiveMailModelOnCI()
        let model = try XCTUnwrap(MailSnapshots.thread().mail)
        var entries: [MailThreadHTML.Entry] = []
        for item in try XCTUnwrap(model.selectedConversation).messages {
            entries.append(.init(message: item.summary, body: await model.conversationBody(item.summary)))
        }
        let html = MailThreadHTML.render(entries, prefersPlain: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: MailHTMLView(html: html, loadsRemote: false))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var web: WKWebView?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            web = Self.webView(in: window.contentView)
            if let web, !web.isLoading,
               (try? await web.evaluateJavaScript("document.querySelectorAll('.jev-message').length") as? Int) == 4 { break }
        }
        let view = try XCTUnwrap(web)
        let text = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertTrue(text.contains("Confirmed. See you Friday at 10!"))
        // A read reply after the newest two starts closed: one line, with its text ready to open.
        let whole = try await view.evaluateJavaScript("document.body.textContent") as? String ?? ""
        XCTAssertTrue(whole.contains("Are you free to review the designs this week?"))
        let open = try await view.evaluateJavaScript("document.querySelectorAll('details.jev-message[open]').length") as? Int
        XCTAssertEqual(open, MailThreadHTML.openReplies)
        XCTAssertFalse(text.contains("Re: Friday's Plan"), "The reader's header shows the subject, so the document does not repeat it.")
        let avatars = try await view.evaluateJavaScript("document.querySelectorAll('.jev-avatar').length") as? Int
        XCTAssertEqual(avatars, 4, "Each reply has its sender's initials.")
        XCTAssertFalse(text.contains("Earlier message repeated here."))
        let pills = try await view.evaluateJavaScript("document.querySelectorAll('details.jev-more').length") as? Int
        XCTAssertEqual(pills, 4, "Quoted text hides behind a ••• pill, not a checkbox.")
        let inputs = try await view.evaluateJavaScript("document.querySelectorAll('input').length") as? Int
        XCTAssertEqual(inputs, 0)
        _ = try await view.evaluateJavaScript("document.querySelector('details.jev-more').open = true")
        let revealed = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertTrue(revealed.contains("Earlier message repeated here."), "Quoted content stays available without nesting it by default.")
    }

    func testClickingASenderMarksThatReplyInPlaceAndSelectsIt() async throws {
        try skipLiveMailModelOnCI()
        let model = try XCTUnwrap(MailSnapshots.thread().mail)
        var entries: [MailThreadHTML.Entry] = []
        for item in try XCTUnwrap(model.selectedConversation).messages {
            entries.append(.init(message: item.summary, body: await model.conversationBody(item.summary)))
        }
        let pick = MailThreadHTML.newPick()
        // A link inside a reply's own text that guesses a sender link: it must not reach the app.
        let fake = entries[1].body.map { body in
            MailModel.Body(message: body.message, html: (body.html ?? "") + "<a id=\"fake\" href=\"#jev-pick-102\">Fake</a>")
        }
        entries[1] = .init(message: entries[1].message, body: fake)
        let html = MailThreadHTML.render(entries, prefersPlain: false, pick: pick)
        var picked: [Int64] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        func reader(fits: Bool, marked: Int64) -> MailHTMLView {
            MailHTMLView(html: html, loadsRemote: false, fitsWidth: fits, selectMessage: { picked.append($0) },
                         surface: .thread, pickPrefix: pick, marked: marked)
        }
        let host = NSHostingView(rootView: reader(fits: true, marked: 100))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var web: WKWebView?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            web = Self.webView(in: window.contentView)
            if let web, !web.isLoading,
               (try? await web.evaluateJavaScript("document.querySelectorAll('.jev-message').length") as? Int) == 4 { break }
        }
        let view = try XCTUnwrap(web)
        func marked() async throws -> [String] {
            let script = "Array.from(document.querySelectorAll('.jev-message')).filter(e => getComputedStyle(e).boxShadow !== 'none').map(e => e.id).join(',')"
            return (try await view.evaluateJavaScript(script) as? String ?? "").split(separator: ",").map(String.init)
        }
        func settle() async throws {
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if !view.isLoading, view.alphaValue == 1,
                   (try? await view.evaluateJavaScript("document.querySelectorAll('.jev-message').length") as? Int) == 4 { return }
            }
        }
        let value1 = try await marked()
        XCTAssertEqual(value1, [pick + "100"], "The selected reply has the mark.")
        _ = try await view.evaluateJavaScript("document.getElementById('fake').click()")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(picked, [], "A link in a message cannot select a reply.")
        let value2 = try await marked()
        XCTAssertEqual(value2, [pick + "100"])
        _ = try await view.evaluateJavaScript("document.querySelector('[id=\"" + pick + "101\"] a.jev-from').click()")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(picked, [101], "The click selects that reply.")
        let value3 = try await marked()
        XCTAssertEqual(value3, [pick + "101"], "The mark moves to the clicked reply, and only one reply has it.")
        let value4 = try await view.evaluateJavaScript("document.querySelectorAll('.jev-message').length") as? Int
        XCTAssertEqual(value4, 4)
        // The selection follows the click; the same document stays, with nothing to load.
        host.rootView = reader(fits: true, marked: 101)
        try await Task.sleep(nanoseconds: 300_000_000)
        let value5 = try await marked()
        XCTAssertEqual(value5, [pick + "101"])
        // Fit Wide Mail to Width loads the document again: the mark is on the selected reply, not the first one.
        host.rootView = reader(fits: false, marked: 101)
        try await settle()
        let value6 = try await marked()
        XCTAssertEqual(value6, [pick + "101"], "After a reload the mark and the actions agree.")
        // A selection made outside the page, such as from the list, moves the mark too.
        host.rootView = reader(fits: false, marked: 102)
        try await settle()
        let value7 = try await marked()
        XCTAssertEqual(value7, [pick + "102"])
    }

    func testOldDocumentHidesUntilTheNextMessageDraws() async throws {
        try skipLiveMailModelOnCI()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: MailHTMLView(html: "<p>First</p>", documentID: 1, loadsRemote: false, surface: .message))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var web: WKWebView?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            web = Self.webView(in: window.contentView)
            if let web, !web.isLoading, web.alphaValue == 1 { break }
        }
        let view = try XCTUnwrap(web)
        XCTAssertEqual(view.alphaValue, 1, "The first message shows once it draws")
        host.rootView = MailHTMLView(html: "<p>Second</p>", documentID: 2, loadsRemote: false, surface: .message)
        host.layoutSubtreeIfNeeded()
        var hidden = view.alphaValue == 0
        for _ in 0..<20 where !hidden { RunLoop.main.run(until: Date().addingTimeInterval(0.002)); hidden = view.alphaValue == 0 }
        XCTAssertTrue(hidden, "The old body hides at once under the new header")
        for _ in 0..<50 where view.alphaValue == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(view.alphaValue, 1, "It shows again once the new message commits")
        let text = try await view.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertEqual(text, "Second")
        // The same message with another setting loads again, but nothing hides.
        host.rootView = MailHTMLView(html: "<p>Second</p>", documentID: 2, loadsRemote: false, fitsWidth: false, surface: .message)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.002)); XCTAssertEqual(view.alphaValue, 1) }
    }

    func testOnlyTheShownPrefixPicksAReply() {
        XCTAssertEqual(MailHTMLView.Coordinator.pickedMessage(URL(string: "about:blank#jev-ab12cd34-101"), prefix: "jev-ab12cd34-"), 101)
        XCTAssertNil(MailHTMLView.Coordinator.pickedMessage(URL(string: "about:blank#jev-pick-101"), prefix: "jev-ab12cd34-"),
                     "A link in a message cannot guess the prefix.")
        XCTAssertNil(MailHTMLView.Coordinator.pickedMessage(URL(string: "https://example.com/#jev-ab12cd34-101"), prefix: "jev-ab12cd34-"))
        XCTAssertNil(MailHTMLView.Coordinator.pickedMessage(URL(string: "about:blank#jev-ab12cd34-x"), prefix: "jev-ab12cd34-"))
        XCTAssertNil(MailHTMLView.Coordinator.pickedMessage(URL(string: "about:blank#101"), prefix: nil))
        XCTAssertEqual(MailHTMLView.Coordinator.pickedMessage(URL(string: "about:blank%23jev-ab12cd34-102"), prefix: "jev-ab12cd34-"), 102,
                       "WebKit hands the link over with its # escaped")
        XCTAssertNotEqual(MailThreadHTML.newPick(), MailThreadHTML.newPick())
    }

    func testOnlyThisConversationsSenderLinksReachTheApp() {
        typealias C = MailHTMLView.Coordinator
        let pick = "jev-ab12cd34-"
        XCTAssertEqual(C.decision(URL(string: "about:blank#jev-ab12cd34-101"), linkActivated: true, mainFrame: true, prefix: pick), .pick(101))
        XCTAssertEqual(C.decision(URL(string: "jevcast-message://select/101"), linkActivated: true, mainFrame: true, prefix: pick), .block,
                       "The old selection link does nothing")
        XCTAssertEqual(C.decision(URL(string: "about:blank#jev-pick-101"), linkActivated: true, mainFrame: true, prefix: pick), .block)
        XCTAssertEqual(C.decision(URL(string: "about:blank#jev-ab12cd34-101"), linkActivated: true, mainFrame: false, prefix: pick), .block,
                       "A frame cannot pick a reply")
        XCTAssertEqual(C.decision(URL(string: "about:blank#jev-ab12cd34-101"), linkActivated: true, mainFrame: true, prefix: nil), .block)
        XCTAssertEqual(C.decision(URL(string: "https://example.com"), linkActivated: true, mainFrame: true, prefix: pick),
                       .open(URL(string: "https://example.com")!))
        XCTAssertEqual(C.decision(URL(string: "mailto:sam@example.com"), linkActivated: true, mainFrame: true, prefix: pick),
                       .open(URL(string: "mailto:sam@example.com")!))
        XCTAssertEqual(C.decision(URL(string: "file:///etc/hosts"), linkActivated: true, mainFrame: true, prefix: pick), .block)
        XCTAssertEqual(C.decision(URL(string: "about:blank"), linkActivated: false, mainFrame: true, prefix: pick), .load)
        XCTAssertEqual(C.decision(URL(string: "https://example.com"), linkActivated: false, mainFrame: true, prefix: pick), .block,
                       "Nothing navigates the page away")
        XCTAssertEqual(C.decision(URL(string: "about:blank"), linkActivated: false, mainFrame: false, prefix: pick), .block)
    }

    func testAReloadAlwaysMarksTheSelectedReply() {
        var state = MailHTMLView.LoadState()
        let key = MailHTMLView.DocumentKey(id: 100, html: "a", images: [:], remote: false, fitsWidth: true, surface: .thread)
        XCTAssertEqual(state.change(to: key, mark: 100), .init(hides: true), "The first document hides until it draws")
        XCTAssertNil(state.change(to: key, mark: 100))
        state.picked(101)
        XCTAssertNil(state.change(to: key, mark: 101), "A sender click moved the mark in place: no reload")
        let wide = MailHTMLView.DocumentKey(id: 100, html: "a", images: [:], remote: false, fitsWidth: false, surface: .thread)
        XCTAssertEqual(state.change(to: wide, mark: 101), .init(hides: false), "A setting reloads the same message without hiding it")
        XCTAssertEqual(state.change(to: wide, mark: 102), .init(hides: false), "A selection from outside moves the mark")
        let other = MailHTMLView.DocumentKey(id: 7, html: "b", images: [:], remote: false, fitsWidth: false, surface: .card)
        XCTAssertEqual(state.change(to: other, mark: nil), .init(hides: true), "Another message hides the old body")
        let document = MailHTMLView.document("x", surface: .thread, mark: MailThreadHTML.mark(101, pick: "jev-t-"))
        XCTAssertTrue(document.hasSuffix("body:not(:has(.jev-message:target)) #jev-t-101{box-shadow:inset 3px 0 0 #0a84ff;"
            + "box-shadow:inset 3px 0 0 -apple-system-control-accent}</style>"), "The mark comes last, so the sender cannot hide it")
    }

    func testQuotedTextOpensForTheKeyboardAndKeepsAFocusRing() throws {
        let message = MailSummary(rowID: 7, mailbox: 1, subject: "Plan", senderName: "Sam", senderAddress: "sam@example.com",
                                  snippet: "Hi", date: Date(), read: true, flagged: false, conversation: 1)
        let raw = "From: sam@example.com\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Hi</p><div class=\"gmail_quote\">Old</div>"
        let detail = try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8)))
        let entries = [MailThreadHTML.Entry(message: message, body: .init(message: detail, html: detail.html))]
        XCTAssertTrue(MailThreadHTML.render(entries, prefersPlain: false).contains("<details class=\"jev-more\"><summary"))
        XCTAssertTrue(MailThreadHTML.render(entries, prefersPlain: false, quotesOpen: true).contains("<details class=\"jev-more\" open><summary"))
        XCTAssertTrue(MailThreadHTML.style.contains("summary:focus-visible{outline:2px solid"), "Tab shows where the focus is")
        XCTAssertFalse(MailThreadHTML.style.contains(";outline:none"), "No summary loses its focus ring for keyboard users")

        let model = try XCTUnwrap(MailSnapshots.thread().mail)
        let thread = try XCTUnwrap(model.shownThread)
        XCTAssertFalse(model.quotesShown)
        XCTAssertEqual(MailReaderToolbarItem.quotedTextTitle(shown: model.quotesShown), "Show Quoted Text")
        model.toggleQuotedText()
        XCTAssertEqual(model.quotesShownIn, thread.id)
        XCTAssertEqual(MailReaderToolbarItem.quotedTextTitle(shown: model.quotesShown), "Hide Quoted Text")
        model.select(2, byUser: true)
        XCTAssertNil(model.shownThread, "One message has no conversation document")
        XCTAssertFalse(model.quotesShown)
        model.toggleQuotedText()
        XCTAssertEqual(model.quotesShownIn, thread.id, "Nothing to open for one message")
    }

    func testSenderHTMLCannotInjectMessageActionsOrGlobalDocumentWrappers() {
        let html = MailHTML.threadFragment("<html><head><style>body{color:red}</style></head><body><a href='jevcast-message://select/99'>Fake action</a><script>bad()</script><p>Reply</p></body></html>", className: "thread-1")
        XCTAssertFalse(html.contains("jevcast-message:"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<body"))
        XCTAssertTrue(html.contains(".thread-1{color:red}"))
        XCTAssertTrue(html.contains("<p>Reply</p>"))
    }

    private static func webView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }
}
