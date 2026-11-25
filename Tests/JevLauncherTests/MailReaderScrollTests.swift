import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import JevLauncher

/// Space in a real plain-text scroll view and a real script-free web view, in hidden windows of the
/// test's own. No keys are posted; the test calls the page action that Space calls.
@MainActor
final class MailReaderScrollTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func show(_ view: NSView, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.alphaValue = 0; window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        windows.append(window)
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = first(type, in: child) { return match } }
        return nil
    }

    func testSpacePagesPlainTextThenGoesOnAtTheEnd() throws {
        let scroll = MailReaderScroll()
        let text = (1...120).map { "Line \($0) of a plain message." }.joined(separator: "\n")
        let root = ScrollView(.vertical) {
            Text(text).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background { MailScrollProbe(scroll: scroll) }
        }
        .frame(width: 320, height: 300)
        let host = NSHostingView(rootView: root)
        show(host, size: NSSize(width: 320, height: 300))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let scrollView = try XCTUnwrap(first(NSScrollView.self, in: host))
        func top() -> CGFloat { scrollView.contentView.bounds.minY }

        var ends = 0
        let start = top()
        scroll.page(down: true) { ends += 1 }
        XCTAssertGreaterThan(top(), start + 200, "Space moves about one page")
        XCTAssertEqual(ends, 0)
        var presses = 1
        while ends == 0, presses < 100 { scroll.page(down: true) { ends += 1 }; presses += 1 }
        XCTAssertEqual(ends, 1, "At the end, Space goes on to the next message")
        let bottom = top()
        scroll.page(down: false) { XCTFail("⇧Space never goes to another message") }
        XCTAssertLessThan(top(), bottom, "⇧Space moves up")
    }

    func testSpacePagesAScriptFreeWebPageAndFindsItsEnd() async throws {
        let scroll = MailReaderScroll()
        let html = (1...40).map { "<p>Paragraph \($0) of an HTML message.</p>" }.joined()
        let host = NSHostingView(rootView: MailHTMLView(html: html, documentID: 1, loadsRemote: false, scroll: scroll, surface: .message)
            .frame(width: 320, height: 300))
        show(host, size: NSSize(width: 320, height: 300))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let web = try XCTUnwrap(first(WKWebView.self, in: host))
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript, "Mail scripts stay off")
        XCTAssertEqual(web.value(forKey: "drawsBackground") as? Bool, false, "The reader's web view draws on the pane's surface")
        // The test reads the position; the app never runs a script to scroll or measure.
        func top() async -> Double { (try? await web.evaluateJavaScript("window.scrollY") as? Double) ?? -1 }

        var ends = 0
        scroll.page(down: true) { ends += 1 }
        try await Task.sleep(nanoseconds: 500_000_000)
        let first = await top()
        XCTAssertGreaterThan(first, 100, "Space moves the page")
        var presses = 1
        while ends == 0, presses < 40 {
            scroll.page(down: true) { ends += 1 }
            try await Task.sleep(nanoseconds: 450_000_000)
            presses += 1
        }
        XCTAssertEqual(ends, 1, "Once the page stops moving, Space goes on to the next message")
        let bottom = await top()
        XCTAssertGreaterThan(bottom, first)
        scroll.page(down: false) { XCTFail("⇧Space never goes to another message") }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let afterUp = await top()
        XCTAssertLessThan(afterUp, bottom - 100, "⇧Space moves up about a page, also from the end")
    }

    /// Quick presses never measure the same frame twice, and a measurement made for a page that
    /// has since changed, such as another message, never moves on.
    func testQuickPressesAndANewDocumentNeverSkipAMessage() async throws {
        let scroll = MailReaderScroll()
        let html = (1...40).map { "<p>Paragraph \($0) of an HTML message.</p>" }.joined()
        let host = NSHostingView(rootView: MailHTMLView(html: html, documentID: 1, loadsRemote: false, scroll: scroll, surface: .message)
            .frame(width: 320, height: 300))
        show(host, size: NSSize(width: 320, height: 300))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let web = try XCTUnwrap(first(WKWebView.self, in: host))
        func top() async -> Double { (try? await web.evaluateJavaScript("window.scrollY") as? Double) ?? -1 }

        var ends = 0
        // Three presses at once: one page, measured once; the others are ignored.
        for _ in 0..<3 { scroll.page(down: true) { ends += 1 } }
        XCTAssertTrue(scroll.measuring)
        while scroll.measuring { try await Task.sleep(nanoseconds: 50_000_000) }
        let once = await top()
        XCTAssertGreaterThan(once, 100)
        scroll.page(down: true) { ends += 1 }
        while scroll.measuring { try await Task.sleep(nanoseconds: 50_000_000) }
        let twice = await top()
        XCTAssertGreaterThan(twice, once + 100, "The quick presses moved one page, not three")
        XCTAssertEqual(ends, 0)

        // Go to the very end, then press while the page changes to another document.
        for _ in 0..<20 {
            scroll.page(down: true) { ends += 1 }
            while scroll.measuring { try await Task.sleep(nanoseconds: 50_000_000) }
            if ends > 0 { break }
        }
        XCTAssertEqual(ends, 1, "At the end, the press that moved nothing goes on")
        scroll.page(down: true) { ends += 1 }
        scroll.documentChanged(web)
        while scroll.measuring { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(ends, 1, "A measurement for the old document is dropped")
    }

    /// A conversation starts as a style alone, before its first reply loads. Space then does
    /// nothing: an empty page looks the same before and after a page down and would skip the
    /// conversation.
    func testSpaceWaitsUntilTheDocumentHasContent() async throws {
        let scroll = MailReaderScroll()
        let host = NSHostingView(rootView: MailHTMLView(html: MailThreadHTML.style, documentID: 1, loadsRemote: false, scroll: scroll,
                                                        surface: .thread, hasContent: false)
            .frame(width: 320, height: 300))
        show(host, size: NSSize(width: 320, height: 300))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(scroll.webPageReady)
        var ends = 0
        scroll.page(down: true) { ends += 1 }
        XCTAssertFalse(scroll.measuring, "Nothing is measured")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(ends, 0, "Space never goes on before the reply shows")

        let html = (1...40).map { "<p>Paragraph \($0) of an HTML message.</p>" }.joined()
        host.rootView = MailHTMLView(html: html, documentID: 1, loadsRemote: false, scroll: scroll, surface: .thread, hasContent: true)
            .frame(width: 320, height: 300)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(scroll.webPageReady, "Once the reply has committed, Space pages")
    }

    /// A document that never commits leaves the previous message in the view. It stays hidden and
    /// a short line says the message could not be shown.
    func testAFailedLoadNeverShowsThePreviousMessage() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        show(web, size: NSSize(width: 320, height: 300))
        let coordinator = MailHTMLView.Coordinator()
        coordinator.surface = .message
        web.navigationDelegate = coordinator
        web.loadHTMLString("<p>Previous message</p>", baseURL: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let navigation = web.loadHTMLString("<p>Requested message</p>", baseURL: nil)
        coordinator.hide(web, until: navigation)
        coordinator.webView(web, didFailProvisionalNavigation: navigation, withError: URLError(.cannotDecodeContentData))
        XCTAssertEqual(web.alphaValue, 0, "The previous message stays hidden")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let text = try await web.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines), "This message could not be shown.")
        XCTAssertEqual(web.alphaValue, 1)
        XCTAssertTrue(coordinator.showingFailure)
    }
}
