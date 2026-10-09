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
        XCTAssertTrue(text.contains("Are you free to review the designs this week?"))
        XCTAssertFalse(text.contains("Earlier message repeated here."))
        _ = try await view.evaluateJavaScript("document.querySelector('.jev-quotes').checked = true")
        let revealed = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertTrue(revealed.contains("Earlier message repeated here."), "Quoted content stays available without nesting it by default.")
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
