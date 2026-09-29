import XCTest
@testable import LauncherCore

final class MailComposerTests: XCTestCase {
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testPlainASCIIMessage() {
        var message = OutgoingMessage(from: MailContact(name: "Ryan", address: "ryan@yahoo.ie"),
                                      to: [MailContact(name: "Sam", address: "sam@example.com"), MailContact(address: "ann@example.com")],
                                      subject: "Lunch on Friday", body: "Works for me.\nSee you.")
        message.date = Date(timeIntervalSince1970: 0)
        message.messageID = "<fixed@yahoo.ie>"
        let rendered = text(MailComposer.render(message))
        XCTAssertTrue(rendered.contains("From: Ryan <ryan@yahoo.ie>\r\n"))
        XCTAssertTrue(rendered.contains("To: Sam <sam@example.com>, ann@example.com\r\n"))
        XCTAssertTrue(rendered.contains("Subject: Lunch on Friday\r\n"))
        XCTAssertTrue(rendered.contains("Message-ID: <fixed@yahoo.ie>\r\n"))
        XCTAssertTrue(rendered.contains("Content-Transfer-Encoding: 7bit\r\n"))
        XCTAssertTrue(rendered.hasSuffix("\r\n\r\nWorks for me.\r\nSee you.\r\n"))
        XCTAssertFalse(rendered.contains("Bcc"))
    }

    func testNonASCIIRoundTripsThroughTheParser() throws {
        var message = OutgoingMessage(from: MailContact(name: "Seán Ó Briain", address: "sean@yahoo.ie"),
                                      to: [MailContact(name: "Zoë", address: "zoe@example.com")],
                                      subject: "Café plans ☕ for the weekend, with a subject long enough to need more than one encoded word",
                                      body: "Grand, see you at the café.\nPrice: 5 € = cheap\nTrailing space ")
        message.cc = [MailContact(name: "Team, Sales", address: "sales@example.com")]
        let data = MailComposer.render(message)
        XCTAssertTrue(data.allSatisfy { $0 < 0x80 }, "Headers and body are 7-bit on the wire")
        for line in text(data).components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.count, 78, line) }
        let parsed = try XCTUnwrap(MIMEMessage.parse(data))
        XCTAssertEqual(parsed.header("Subject"), message.subject)
        XCTAssertEqual(parsed.header("From"), "Seán Ó Briain <sean@yahoo.ie>")
        XCTAssertEqual(parsed.header("Cc"), "\"Team, Sales\" <sales@example.com>")
        XCTAssertEqual(parsed.plainText, "Grand, see you at the café.\r\nPrice: 5 € = cheap\r\nTrailing space \r\n")
    }

    func testHeaderValuesCannotAddHeaders() {
        let message = OutgoingMessage(from: MailContact(name: "Me\r\nBcc: victim@example.com", address: "me@example.com"),
                                      to: [MailContact(address: "sam@example.com")], subject: "Hi\r\nX-Injected: yes", body: "Body")
        let rendered = text(MailComposer.render(message))
        XCTAssertFalse(rendered.contains("\r\nBcc:"))
        XCTAssertFalse(rendered.contains("\r\nX-Injected:"))
    }

    func testAttachmentsAndForwardedMessage() throws {
        var message = OutgoingMessage(from: MailContact(address: "me@example.com"), to: [MailContact(address: "sam@example.com")], subject: "Files", body: "Attached.")
        message.attachments = [
            .init(filename: "report 2026.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 300)),
            .init(filename: "Forwarded message.eml", mimeType: "message/rfc822", data: Data("Subject: Old\r\n\r\nOld text\r\n".utf8)),
            .init(filename: "Résumé.txt", mimeType: "text/plain", data: Data("x".utf8)),
        ]
        let data = MailComposer.render(message)
        let parsed = try XCTUnwrap(MIMEMessage.parse(data))
        XCTAssertEqual(parsed.plainText, "Attached.\r\n")
        XCTAssertEqual(parsed.attachments.map(\.name), ["report 2026.pdf", "Résumé.txt"])
        XCTAssertEqual(parsed.attachments.first?.size, 300)
        XCTAssertTrue(text(data).contains("Content-Type: message/rfc822\r\n"))
    }

    func testQuotedPrintableSoftBreaks() {
        let long = String(repeating: "é", count: 60)
        let encoded = MailComposer.quotedPrintable(long)
        XCTAssertTrue(encoded.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        XCTAssertEqual(String(decoding: QuotedPrintable.decode(Data(encoded.utf8)), as: UTF8.self), long)
        XCTAssertEqual(MailComposer.quotedPrintable("a = b \r\nnext"), "a =3D b=20\r\nnext")
    }

    // MARK: Replies

    func testReplySubjectsAndRecipients() throws {
        XCTAssertEqual(MailReplies.replySubject("Lunch"), "Re: Lunch")
        XCTAssertEqual(MailReplies.replySubject("RE: Lunch"), "RE: Lunch")
        XCTAssertEqual(MailReplies.forwardSubject("Fw: Lunch"), "Fw: Lunch")
        XCTAssertEqual(MailReplies.forwardSubject("Lunch"), "Fwd: Lunch")
        let original = try XCTUnwrap(MIMEMessage.parse(Data("""
        From: Sam <sam@example.com>\r
        Reply-To: Team <team@example.com>\r
        To: Me <ME@yahoo.ie>, Ann <ann@example.com>\r
        Cc: sam@example.com, Bob <bob@example.com>\r
        Message-ID: <m2@example.com>\r
        References: <m0@example.com> <m1@example.com>\r
        Subject: Plans\r
        \r
        Line one\r
        \r
        Line three\r

        """.utf8)))
        let single = MailReplies.recipients(of: original, all: false, own: ["me@yahoo.ie"])
        XCTAssertEqual(single.to.map(\.address), ["team@example.com"])
        XCTAssertTrue(single.cc.isEmpty)
        let all = MailReplies.recipients(of: original, all: true, own: ["me@yahoo.ie"])
        XCTAssertEqual(all.cc.map(\.address), ["ann@example.com", "sam@example.com", "bob@example.com"])
        let threading = MailReplies.references(of: original)
        XCTAssertEqual(threading.inReplyTo, "<m2@example.com>")
        XCTAssertEqual(threading.references, ["<m0@example.com>", "<m1@example.com>", "<m2@example.com>"])
        let body = MailReplies.replyBody("Sounds good.", original: original, sender: "Sam <sam@example.com>", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(body.hasPrefix("Sounds good.\n\nOn "))
        XCTAssertTrue(body.contains("Sam <sam@example.com> wrote:\n\n> Line one\n>\n> Line three"))
    }

    func testReplyToOwnMessageGoesToItsRecipients() throws {
        let original = try XCTUnwrap(MIMEMessage.parse(Data("From: Me <me@yahoo.ie>\r\nTo: Sam <sam@example.com>\r\nSubject: x\r\n\r\nbody\r\n".utf8)))
        XCTAssertEqual(MailReplies.recipients(of: original, all: false, own: ["me@yahoo.ie"]).to.map(\.address), ["sam@example.com"])
    }

    // MARK: SMTP

    func testDotStuffing() {
        XCTAssertEqual(String(decoding: SMTPClient.dotStuffed(Data("a\n.b\r\n..c".utf8)), as: UTF8.self), "a\r\n..b\r\n...c\r\n.\r\n")
        XCTAssertEqual(String(decoding: SMTPClient.dotStuffed(Data(".\r\n".utf8)), as: UTF8.self), "..\r\n.\r\n")
    }

    func testRejectsUnsafeAddresses() {
        XCTAssertTrue(SMTPClient.isSafeAddress("sam@example.com"))
        for bad in ["sam", "sam@", "a b@example.com", "sam@example.com>\r\nRCPT TO:<x@y.z", "zoë@example.com", "a@b@c"] {
            XCTAssertFalse(SMTPClient.isSafeAddress(bad), bad)
        }
    }

    func testSendsThroughSMTP() async throws {
        let server = FakeSMTPServer()
        let client = SMTPClient(settings: .init(server: MailServer(host: "smtp.example.com", port: 465, security: .tls), username: "me@example.com"),
                                credential: { .password("app-password") }, transport: { _, _, _ in server.connect() })
        let message = OutgoingMessage(from: MailContact(address: "me@example.com"), to: [MailContact(address: "sam@example.com")], subject: "Hi", body: ".leading dot\nok")
        try await client.send(from: "me@example.com", recipients: message.recipients, message: MailComposer.render(message))
        let delivery = try XCTUnwrap(server.delivered.first)
        XCTAssertEqual(delivery.from, "<me@example.com>")
        XCTAssertEqual(delivery.recipients, ["sam@example.com"])
        XCTAssertTrue(String(decoding: delivery.data, as: UTF8.self).contains("\r\n..leading dot\r\n"))
    }

    func testSMTPReportsRefusalsAndBadPasswords() async throws {
        let server = FakeSMTPServer()
        server.refused = ["gone@example.com"]
        let settings = SMTPClient.Settings(server: MailServer(host: "smtp.example.com", port: 587, security: .startTLS), username: "me@example.com")
        server.startTLS = true
        let client = SMTPClient(settings: settings, credential: { .password("app-password") }, transport: { _, _, _ in server.connect() })
        do {
            try await client.send(from: "me@example.com", recipients: ["gone@example.com"], message: Data("Subject: x\r\n\r\ny\r\n".utf8))
            XCTFail("A refused recipient must fail the send")
        } catch MailError.smtp(let code, let text) {
            XCTAssertEqual(code, 550)
            XCTAssertTrue(text.contains("gone@example.com"))
        }
        let wrong = SMTPClient(settings: settings, credential: { .password("nope") }, transport: { _, _, _ in server.connect() })
        do { try await wrong.verify(); XCTFail("A wrong password must fail") } catch MailError.signInFailed {}
        server.startTLS = false
        do { try await client.verify(); XCTFail("STARTTLS is required on a STARTTLS account") } catch MailError.noSecureConnection {}
        XCTAssertTrue(server.delivered.isEmpty)
    }
}
