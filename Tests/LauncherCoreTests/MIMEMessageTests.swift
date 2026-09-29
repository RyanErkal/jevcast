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
            XCTAssertTrue(script.contains("set m to first message of mb whose id is mid"))
            XCTAssertTrue(script.contains("tell application id \"com.apple.mail\""))
        }
        XCTAssertTrue(MailScripts.send.contains("subject:(item 3 of argv), content:(item 4 of argv)"))
        XCTAssertTrue(MailScripts.synchronize.contains("synchronize with (first account whose id is (a as text))"))
        XCTAssertTrue(MailScripts.synchronize.contains("repeat with a in argv"))
    }

    /// The scripts that send, their message variable, and how many `argv` items they read. The last
    /// item is `checkText`.
    private let sendingScripts = [(MailScripts.reply, "r", 6), (MailScripts.forward, "f", 6), (MailScripts.send, "o", 5)]

    /// Mail can ignore text set on a message it has not shown. The scripts read it back first and
    /// send nothing without it. Mail's copy must start with the text, so a quoted original that
    /// contains the same words, such as "Thanks,", does not pass the check.
    func testSendingScriptsCheckTheTextBeforeSending() throws {
        for (script, message, argument) in sendingScripts {
            let rules = try XCTUnwrap(script.range(of: "considering case but ignoring white space"))
            let check = try XCTUnwrap(script.range(of: "set kept to written starts with (item \(argument) of argv)"))
            let sending = try XCTUnwrap(script.range(of: "(send \(message))"))
            XCTAssertLessThan(rules.lowerBound, check.lowerBound)
            XCTAssertLessThan(check.lowerBound, sending.lowerBound, "The check comes before the send")
            XCTAssertTrue(script.contains("set written to (content of \(message)) as text"))
            XCTAssertFalse(script.contains(" contains (item"), "Text anywhere in the message does not count")
            XCTAssertTrue(script.contains("error \"Mail did not take the text, so nothing was sent.\" number 1003"))
            let items = script.components(separatedBy: "(item ").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
            XCTAssertEqual(items.max(), argument, "The check text is the last argument")
        }
        // Mail's own text that already starts with the reply, such as a signature, does not count as the reply.
        for script in [MailScripts.reply, MailScripts.forward] {
            XCTAssertTrue(script.contains("if kept and quoted starts with (item 6 of argv) then set kept to written does not start with quoted"))
        }
        XCTAssertTrue(MailScripts.reply.contains("set content of r to (item 4 of argv) & return & return & quoted"), "The reply text comes first")
        XCTAssertTrue(MailScripts.forward.contains("set content of f to (item 4 of argv) & return & return & quoted"), "The note comes first")
    }

    /// An error before `send` is 1004: nothing was sent. An error from `send` itself is 1005: Mail may
    /// have sent the message. A message Mail would not send (1002) is closed without saving.
    func testSendingScriptsNumberTheirErrors() throws {
        for (script, message, _) in sendingScripts {
            let start = try XCTUnwrap(script.range(of: "      try\n"))
            let make = try XCTUnwrap(script.range(of: "set \(message) to "))
            let before = try XCTUnwrap(script.range(of: "error errText number 1004"))
            let sending = try XCTUnwrap(script.range(of: "set didSend to (send \(message))"))
            let during = try XCTUnwrap(script.range(of: "error \"Mail stopped while it sent the message.\" number 1005"))
            let refused = try XCTUnwrap(script.range(of: "error \"Mail did not send the message.\" number 1002"))
            XCTAssertLessThan(start.lowerBound, make.lowerBound, "Making the message is inside the 1004 block")
            XCTAssertLessThan(before.lowerBound, sending.lowerBound)
            XCTAssertLessThan(sending.lowerBound, during.lowerBound)
            XCTAssertLessThan(during.lowerBound, refused.lowerBound)
            let discard = try XCTUnwrap(script[during.upperBound...].range(of: "close \(message) saving no"))
            XCTAssertLessThan(discard.lowerBound, refused.lowerBound, "The 1002 path discards the message")
            XCTAssertTrue(script.contains("if errNum is -1743 or errNum is 1003 then error errText number errNum"),
                          "A refused permission and a failed check keep their numbers")
        }
    }

    /// The text that goes to Mail loses its leading white space, and the check is its first 200 characters.
    func testCheckTextIsTheStartOfTheSentText() {
        XCTAssertEqual(MailScripts.sendingText("\n \t\n\u{00A0} Hello there  \nsecond"), "Hello there  \nsecond")
        XCTAssertEqual(MailScripts.sendingText("Hi\n"), "Hi\n", "Only leading white space goes")
        XCTAssertEqual(MailScripts.checkText("\r\n   \n  Thanks,\nsee you then."), "Thanks,\nsee you then.", "More than the first line")
        XCTAssertEqual(MailScripts.checkText(" \n\t"), "")
        XCTAssertEqual(MailScripts.checkText(String(repeating: "a", count: 300)), String(repeating: "a", count: 200))
        XCTAssertEqual(MailScripts.checkText(String(repeating: "👍🏽", count: 250)).count, 200, "Whole characters")
        let body = "\n\n" + String(repeating: "word ", count: 100)
        XCTAssertTrue(MailScripts.sendingText(body).hasPrefix(MailScripts.checkText(body)))
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

    func testInboxRoleAcrossAccountKinds() {
        let inboxes = [
            "imap://1A2B-GMAIL/INBOX",                  // Gmail
            "imap://C3D4-ICLOUD/INBOX",                 // iCloud
            "ews://E5F6-EXCHANGE/Inbox",                // Exchange and Outlook
            "imap://ABCD-OUTLOOK/Inbox",                // Outlook.com over IMAP
            "imap://7788-YAHOO/Inbox",                  // Yahoo
            "local://local/Inbox",                      // On My Mac
            "local:///Inbox",                           // On My Mac, no host
            "imap://ACC/INBOX/",                        // Trailing slash
            "imap://ACC/inbox"
        ]
        for url in inboxes {
            XCTAssertEqual(MailMailbox(rowID: 1, url: url, unread: 0, total: 0).role, .inbox, url)
        }
        for url in ["imap://A/Old/Inbox", "ews://A/Clients/Inbox", "imap://A/INBOX/Receipts", "imap://A/Inboxes"] {
            XCTAssertNotEqual(MailMailbox(rowID: 1, url: url, unread: 0, total: 0).role, .inbox, url)
        }
        XCTAssertEqual(MailMailbox(rowID: 1, url: "local:///Inbox", unread: 0, total: 0).path, "Inbox")
        let roles: [(String, MailMailbox.Role)] = [
            ("imap://A/%5BGmail%5D/Sent%20Mail", .sent), ("ews://A/Sent%20Items", .sent), ("imap://A/Drafts", .drafts),
            ("imap://A/%5BGmail%5D/Spam", .junk), ("ews://A/Junk%20Email", .junk), ("ews://A/Deleted%20Items", .trash),
            ("imap://A/%5BGmail%5D/Trash", .trash), ("imap://A/Bulk%20Mail", .junk)
        ]
        for (url, role) in roles {
            let box = MailMailbox(rowID: 1, url: url, unread: 0, total: 0)
            XCTAssertEqual(box.role, role, url)
            XCTAssertFalse(box.inAllMail, url)
        }
        XCTAssertTrue(MailMailbox(rowID: 1, url: "imap://A/%5BGmail%5D/All%20Mail", unread: 0, total: 0).inAllMail)
        XCTAssertTrue(MailMailbox(rowID: 1, url: "imap://A/Projects", unread: 0, total: 0).inAllMail)
    }
}

final class InlineImageTests: XCTestCase {
    func testContentIDImagesAreInlineNotAttachments() throws {
        let raw = "Subject: x\nContent-Type: multipart/related; boundary=b\n\n--b\nContent-Type: text/html\n\n<img src=\"cid:logo\">\n--b\nContent-Type: image/png\nContent-ID: <logo>\nContent-Transfer-Encoding: base64\n\nAQID\n--b--\n"
        let message = try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8)))
        XCTAssertEqual(message.inlineImages["logo"]?.data, Data([1, 2, 3]))
        XCTAssertTrue(message.attachments.isEmpty)
    }
}
