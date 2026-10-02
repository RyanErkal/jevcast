import XCTest
@testable import LauncherCore

/// How a reply's quote and a forward look, and the files a forward carries.
final class MailReplyFormatTests: XCTestCase {
    private let original = MIMEMessage.parse(Data("""
    From: Bodhi <bodhi@example.com>\r
    To: me@example.com\r
    Cc: ann@example.com\r
    Subject: Leads\r
    Content-Type: text/html; charset=utf-8\r
    \r
    <html><head><style>p{color:red}</style></head><body><p>Hello</p></body></html>\r
    """.utf8))!

    func testAttributionReadsAsInAppleMail() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 3, minute: 1)))
        XCTAssertEqual(MailReplies.replyAttribution(date: date, sender: "Bodhi <bodhi@example.com>"),
                       "On 2 Oct 2026, at 03:01, Bodhi <bodhi@example.com> wrote:")
    }

    func testQuoteIsACiteBlockWithItsAttributionAndScopedStyles() {
        let html = MailHTML.quoted(original, attribution: "On 2 Oct 2026, at 03:01, Bodhi wrote:")
        XCTAssertTrue(html.hasPrefix("<div><br></div>"), "A blank line for your text comes first")
        XCTAssertTrue(html.contains(#"<blockquote type="cite""#))
        XCTAssertTrue(html.contains("border-left:2px solid"))
        XCTAssertTrue(html.contains("On 2 Oct 2026, at 03:01, Bodhi wrote:</div><br><div><p>Hello</p></div>"))
        XCTAssertTrue(html.hasSuffix("</blockquote>"))
        XCTAssertFalse(html.contains("<head"), "The original's document wrapper never replaces the reply's")
        XCTAssertTrue(html.contains("color:red"), "The original's styles stay, scoped to the quote")
        XCTAssertFalse(html.contains("<style>p{color:red}"), "Unscoped styles would restyle your text")
    }

    func testForwardShowsTheOriginalHeaders() {
        let html = MailHTML.forwarded(original, date: "2 Oct 2026 at 03:01")
        XCTAssertTrue(html.contains("<div>Begin forwarded message:</div>"))
        for row in ["<b>From:</b> Bodhi &lt;bodhi@example.com&gt;", "<b>Subject:</b> Leads", "<b>Date:</b> 2 Oct 2026 at 03:01",
                    "<b>To:</b> me@example.com", "<b>Cc:</b> ann@example.com"] {
            XCTAssertTrue(html.contains(row), row)
        }
    }

    func testReplyWithoutQuoteIsOnlyYourText() {
        XCTAssertEqual(MailReplies.replyBody("Thanks.", original: original, sender: "Bodhi", date: Date(), quote: false), "Thanks.")
    }

    func testFilesKeepTheirBytesAndSkipInlineImages() {
        let raw = Data("""
        Subject: Files\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: multipart/related; boundary="inner"\r
        \r
        --inner\r
        Content-Type: text/html\r
        \r
        <img src="cid:logo">\r
        --inner\r
        Content-Type: image/png\r
        Content-ID: <logo>\r
        Content-Transfer-Encoding: base64\r
        \r
        iVBORw==\r
        --inner--\r
        --outer\r
        Content-Type: text/csv; name="leads.csv"\r
        Content-Disposition: attachment; filename="leads.csv"\r
        \r
        name,phone\r
        --outer\r
        Content-Type: message/rfc822\r
        \r
        Subject: Inner\r
        Content-Type: multipart/mixed; boundary="deep"\r
        \r
        --deep\r
        Content-Type: application/pdf; name="quote.pdf"\r
        Content-Disposition: attachment; filename="quote.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERg==\r
        --deep--\r
        --outer--\r
        """.utf8)
        let files = MIMEMessage.files(raw)
        XCTAssertEqual(files.map(\.name), ["leads.csv", "quote.pdf"])
        XCTAssertEqual(files.first?.data, Data("name,phone".utf8))
        XCTAssertEqual(files.last?.data, Data("%PDF".utf8))
        XCTAssertEqual(MIMEMessage.parse(raw)?.attachments.map(\.name), files.map(\.name), "Same files as the attachment list")
    }
}
