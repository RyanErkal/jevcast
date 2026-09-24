import XCTest
@testable import LauncherCore

final class MIMEMessageTests: XCTestCase {
    func testMultipartAlternativeWithEncodings() throws {
        let raw = """
        From: =?utf-8?B?Sm9zw6k=?= <jose@example.com>
        To: Sam <sam@example.com>, ann@example.com
        Subject: =?iso-8859-1?Q?Caf=E9?= plans
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Hello =E2=9C=93 soft=
        break
        --inner
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        PHA+SGVsbG8gPGI+d29ybGQ8L2I+PC9wPg==
        --inner--
        --outer
        Content-Type: application/pdf; name="report.pdf"
        Content-Disposition: attachment; filename*=utf-8''Q3%20report.pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --outer--
        """
        let message = try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8)))
        XCTAssertEqual(message.header("from"), "José <jose@example.com>")
        XCTAssertEqual(message.header("Subject"), "Café plans")
        XCTAssertEqual(message.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello ✓ softbreak")
        XCTAssertEqual(message.html, "<p>Hello <b>world</b></p>")
        XCTAssertEqual(message.attachments.map(\.name), ["Q3 report.pdf"])
        XCTAssertEqual(message.attachments.first?.size, 9)
        let to = MailAddress.list(message.header("To") ?? "")
        XCTAssertEqual(to.map(\.address), ["sam@example.com", "ann@example.com"])
        XCTAssertEqual(to.first?.name, "Sam")
    }

    func testEMLXEnvelope() throws {
        let body = "Subject: Hi\nContent-Type: text/plain\n\nBody text\n"
        let emlx = "\(body.utf8.count)\n" + body + "<?xml version=\"1.0\"?><plist><dict/></plist>"
        let message = try XCTUnwrap(MIMEMessage.parseEMLX(Data(emlx.utf8)))
        XCTAssertEqual(message.header("subject"), "Hi")
        XCTAssertEqual(message.plainText, "Body text\n")
    }

    func testHTMLOnlyReadableText() throws {
        let raw = "Subject: x\nContent-Type: text/html\n\n<html><head><style>p{}</style></head><body><p>One&nbsp;&amp; two</p><script>alert(1)</script><ul><li>a</li></ul></body></html>"
        let message = try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8)))
        XCTAssertEqual(message.readableText, "One & two\n• a")
    }

    func testEncodedWordsJoinAcrossWhitespace() {
        XCTAssertEqual(EncodedWords.decode("=?utf-8?Q?Hello?= =?utf-8?Q?_world?="), "Hello world")
        XCTAssertEqual(EncodedWords.decode("Plain subject"), "Plain subject")
    }

    func testMailboxPathsAndFiles() {
        let gmail = MailMailbox(rowID: 3, url: "imap://ABC-123/%5BGmail%5D/All%20Mail", unread: 0, total: 10)
        XCTAssertEqual(gmail.accountID, "ABC-123")
        XCTAssertEqual(gmail.path, "[Gmail]/All Mail")
        XCTAssertEqual(gmail.role, .archive)
        XCTAssertEqual(gmail.folder(in: "/M/V10"), "/M/V10/ABC-123/[Gmail].mbox/All Mail.mbox")
        let inbox = MailMailbox(rowID: 1, url: "imap://ABC-123/INBOX", unread: 2, total: 5)
        XCTAssertEqual(inbox.role, .inbox)
        XCTAssertEqual(MailMailbox.archive(for: "ABC-123", in: [inbox, gmail]), gmail)
        XCTAssertEqual(MailFiles.relativePaths(rowID: 123456), ["Data/3/2/1/Messages/123456.emlx", "Data/3/2/1/Messages/123456.partial.emlx"])
        XCTAssertEqual(MailFiles.relativePaths(rowID: 42).first, "Data/Messages/42.emlx")
        XCTAssertEqual(MailFiles.versionFolder(["V2", "V10", "MailData", "V9"]), "V10")
    }

    func testMailScriptsTakeValuesAsArguments() {
        for script in [MailScripts.setRead, MailScripts.setFlagged, MailScripts.delete, MailScripts.move, MailScripts.reply, MailScripts.forward, MailScripts.open] {
            XCTAssertTrue(script.contains("first account whose id is (item 1 of argv)"))
            XCTAssertTrue(script.contains("message id ((item 3 of argv) as integer)"))
            XCTAssertTrue(script.contains("tell application id \"com.apple.mail\""))
        }
        XCTAssertTrue(MailScripts.send.contains("subject:(item 3 of argv), content:(item 4 of argv)"))
    }
}

final class MIMEHostileTests: XCTestCase {
    func testDeeplyNestedForwardsDoNotCrash() {
        var raw = "Subject: leaf\nContent-Type: text/plain\n\nbottom\n"
        for _ in 0..<2000 { raw = "Subject: x\nContent-Type: message/rfc822\n\n" + raw }
        XCTAssertNotNil(MIMEMessage.parse(Data(raw.utf8)), "Parsing stops at the depth limit instead of overflowing the stack.")
    }

    func testEightBitPartsKeepTheirBytes() throws {
        var data = Data("Subject: x\nContent-Type: multipart/alternative; boundary=b\n\n--b\nContent-Type: text/plain; charset=iso-8859-1\nContent-Transfer-Encoding: 8bit\n\ncaf".utf8)
        data.append(0xE9)
        data.append(Data("\n--b--\n".utf8))
        let message = try XCTUnwrap(MIMEMessage.parse(data))
        XCTAssertEqual(message.plainText, "café")
    }

    func testBoundaryOnlyAtLineStart() throws {
        let raw = "Subject: x\nContent-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\n\nsee --b inside\n--b--\n"
        XCTAssertEqual(try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8))).plainText, "see --b inside")
    }

    func testNumericEntities() {
        XCTAssertEqual(HTMLText.plain("It&#8217;s &#x2019;ok&#39;"), "It’s ’ok'")
    }

    func testNestedArchiveAndInboxAreNotChosen() {
        let nested = MailMailbox(rowID: 5, url: "imap://A/Clients/Archive", unread: 0, total: 0)
        let top = MailMailbox(rowID: 6, url: "imap://A/Archive", unread: 0, total: 0)
        XCTAssertEqual(MailMailbox.archive(for: "A", in: [nested, top]), top)
        XCTAssertEqual(MailMailbox(rowID: 7, url: "imap://A/Old/Inbox", unread: 0, total: 0).role, .other)
    }
}
