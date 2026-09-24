import XCTest
@testable import LauncherCore

final class BrowserTabTests: XCTestCase {
    func testParsesTabRecords() {
        let f = TabScripts.field, r = TabScripts.record
        let output = "123\(f)abc\(f)true\(f)Inbox (3)\(f)https://mail.example/\(r)123\(f)def\(f)false\(f)Docs\(f)https://docs.example/a\n\(r)bad\(r)"
        let tabs = TabScripts.parse(output, browser: "com.google.Chrome")
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[0], BrowserTab(browser: "com.google.Chrome", windowID: "123", key: "abc", title: "Inbox (3)", url: "https://mail.example/", active: true))
        XCTAssertEqual(tabs[1].url, "https://docs.example/a")
        XCTAssertEqual(tabs[1].host, "docs.example")
    }

    func testScriptsTakeValuesOnlyAsArguments() {
        for browser in Browser.all {
            for script in [TabScripts.list(browser), TabScripts.focus(browser), TabScripts.close(browser), TabScripts.frontTab(browser)] {
                XCTAssertTrue(script.contains("tell application id \"\(browser.bundleID)\""))
                XCTAssertTrue(script.contains("with timeout"))
            }
            XCTAssertTrue(TabScripts.close(browser).contains("(item 3 of argv)"), "Close checks the URL first.")
        }
        XCTAssertTrue(TabScripts.focus(Browser.named("company.thebrowser.dia")!).contains("focus t"))
        XCTAssertTrue(TabScripts.focus(Browser.named("com.google.Chrome")!).contains("active tab index"))
    }

    func testMarkdownLinksEscape() {
        XCTAssertEqual(Markdown.link("A [b] c", "https://x.example/p(1)"), "[A \\[b\\] c](https://x.example/p%281%29)")
        XCTAssertEqual(Markdown.link("", "https://x.example"), "[https://x.example](https://x.example)")
    }

    func testErrorDetection() {
        XCTAssertTrue(TabScripts.isNotAuthorized("execution error: Not authorized to send Apple events to Google Chrome. (-1743)"))
        XCTAssertFalse(TabScripts.isNotAuthorized("Saving is not allowed here"))
        XCTAssertTrue(TabScripts.isStale("execution error: The tab changed. (1001)"))
    }
}
