import XCTest
@testable import LauncherCore

final class MailSafetyTests: XCTestCase {
    private func client(_ server: FakeIMAPServer) -> IMAPClient {
        IMAPClient(settings: .init(server: .init(host: "imap.example.com", port: 993, security: .tls), username: "me@example.com"),
                   credential: { .password("app-password") }, transport: { _, _, _ in server.connect() })
    }

    func testUIDPlusMoveKeepsUnrelatedDeletedMessages() async throws {
        let server = FakeIMAPServer()
        server.capabilities.removeAll { $0 == "MOVE" }
        let selected = server.deliver(to: "INBOX", subject: "Move only this")
        let other = server.deliver(to: "INBOX", subject: "Preserve this", flags: ["\\Deleted"])
        let client = client(server)
        let info = try await client.select("INBOX")
        try await client.move(uids: IMAPSequenceSet([selected]), to: "Archive", in: "INBOX", validity: info.uidValidity)
        XCTAssertEqual(server.mailbox("INBOX")?.messages.map(\.uid), [other])
        XCTAssertEqual(server.mailbox("Archive")?.messages.count, 1)
        XCTAssertEqual(server.commands("EXPUNGE"), 0)
        XCTAssertEqual(server.commands("UID EXPUNGE"), 1)
        await client.logout()
    }

    func testUnsupportedMoveRefusesBeforeCopyingOrMarking() async throws {
        let server = FakeIMAPServer()
        server.capabilities.removeAll { ["MOVE", "UIDPLUS"].contains($0) }
        let uid = server.deliver(to: "INBOX", subject: "Keep")
        let client = client(server)
        let info = try await client.select("INBOX")
        do { try await client.move(uids: IMAPSequenceSet([uid]), to: "Archive", in: "INBOX", validity: info.uidValidity); XCTFail() }
        catch MailError.notFound(let text) { XCTAssertTrue(text.contains("Nothing was changed")) }
        XCTAssertEqual(server.mailbox("INBOX")?.messages.count, 1)
        XCTAssertEqual(server.mailbox("Archive")?.messages.count, 0)
        XCTAssertEqual(server.commands("UID COPY"), 0)
        XCTAssertEqual(server.commands("UID STORE"), 0)
        XCTAssertEqual(server.commands("EXPUNGE"), 0)
        await client.logout()
    }

    private func smtp(_ server: FakeSMTPServer) -> SMTPClient {
        SMTPClient(settings: .init(server: .init(host: "smtp.example.com", port: 465, security: .tls), username: "me@example.com"),
                   credential: { .password("app-password") }, transport: { _, _, _ in server.connect() })
    }

    func testLostSMTPAcceptanceIsUncertainAndNeverRetried() async throws {
        let server = FakeSMTPServer(); server.acceptThenDisconnect = true
        do { try await smtp(server).send(from: "me@example.com", recipients: ["sam@example.com"], message: Data("Subject: x\r\n\r\nBody\r\n".utf8)); XCTFail() }
        catch MailError.deliveryUncertain {}
        XCTAssertEqual(server.delivered.count, 1)
    }

    func testExplicitSMTPDataRefusalIsKnownFailure() async throws {
        let server = FakeSMTPServer(); server.dataReply = 554
        do { try await smtp(server).send(from: "me@example.com", recipients: ["sam@example.com"], message: Data("Subject: x\r\n\r\nBody\r\n".utf8)); XCTFail() }
        catch MailError.smtp(let code, _) { XCTAssertEqual(code, 554) }
        XCTAssertTrue(server.delivered.isEmpty)
    }

    func testMultipartKeepsFormattingInlineImagesAndSelectedFiles() throws {
        var message = OutgoingMessage(from: .init(address: "me@example.com"), to: [.init(address: "sam@example.com")], subject: "Styled", body: "Hello\nQuote")
        message.html = "<p><b>Hello</b></p><blockquote><i>Quote</i><img src=\"cid:original\"></blockquote>"
        message.inReplyTo = "<q@example.com>"; message.references = ["<q@example.com>"]
        message.attachments = [.init(filename: "inline.png", mimeType: "image/png", data: Data([1, 2, 3]), contentID: "original"),
                               .init(filename: "chosen.pdf", mimeType: "application/pdf", data: Data([4, 5, 6]))]
        let raw = MailComposer.render(message), parsed = try XCTUnwrap(MIMEMessage.parse(raw))
        XCTAssertTrue(parsed.html?.contains("<b>Hello</b>") == true)
        XCTAssertTrue(parsed.html?.contains("<i>Quote</i>") == true)
        XCTAssertEqual(parsed.inlineImages["original"]?.data, Data([1, 2, 3]))
        XCTAssertEqual(parsed.attachments.map(\.name), ["chosen.pdf"])
        XCTAssertEqual(parsed.header("In-Reply-To"), "<q@example.com>")
        XCTAssertTrue(parsed.plainText?.contains("Hello") == true)
    }

    func testAuthoritativeOtherRoleDoesNotSelectNamedArchive() {
        let box = MailMailbox(rowID: 1, url: "imap://acct/Archive", unread: 0, total: 0, serverRole: .other)
        XCTAssertNil(MailMailbox.archive(for: "acct", in: [box]))
    }

    func testQuotedDocumentKeepsScopedHeadStylesAndRemovesActiveContent() throws {
        let message = try XCTUnwrap(MIMEMessage.parse(Data("Content-Type: text/html; charset=utf-8\r\n\r\n<html><head><style>p{font-weight:bold}@media screen{.detail{color:red}}</style></head><body><p class='detail'>Styled quote</p><script>alert(1)</script><a href=jav&#x61;script:bad>Unsafe link</a><img src=cid:kept onerror='bad'></body></html>".utf8)))
        let html = MailHTML.quoted(message, attribution: "Original")
        XCTAssertTrue(html.contains("font-weight:bold"))
        XCTAssertTrue(html.contains(".detail{color:red}"))
        XCTAssertTrue(html.contains("jevcast-quote-"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("onerror"))
        XCTAssertFalse(html.contains("href=jav"))
        XCTAssertTrue(html.contains("src=cid:kept"))
    }

    func testOAuthCannotSendTokensToCustomMailServers() throws {
        var account = NativeMailAccount.preset(.gmail, name: "Fixture", email: "me@example.com")!
        account.authentication = .oauth
        XCTAssertNoThrow(try account.validated())
        account.smtp.host = "other.example.com"
        XCTAssertThrowsError(try account.validated())
    }

    func testQuoteStylesKeepSelectorFunctionsAndCannotStyleRootSiblings() throws {
        let css = #"body{color:red}body + p{color:green}:is(p,h1),[title="," ]{font-weight:bold}@media screen{body ~ div{display:none}.detail{color:blue}}"#
        let scoped = MailQuoteCSS.scope(css, className: "quote")
        XCTAssertTrue(scoped.contains(".quote{color:red}"))
        XCTAssertTrue(scoped.contains(#".quote :is(p,h1),.quote [title="," ]{font-weight:bold}"#))
        XCTAssertFalse(scoped.contains("color:green"))
        XCTAssertFalse(scoped.contains("display:none"))
        XCTAssertTrue(scoped.contains("@media screen{.quote .detail{color:blue}}"))
        let raw = "Content-Type: text/html\r\n\r\n" + #"<html><body style="font-family:serif" class="detail"><p>Quote</p></body></html>"#
        let message = try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8)))
        XCTAssertTrue(MailHTML.quoted(message, attribution: "Original").contains(#"<div style="font-family:serif" class="detail">"#))
    }

    func testNativeMailboxRolesAreExplicitAndDoNotGuessNestedNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NativeMailStore(root: root)
        let entries = [IMAPListEntry(flags: [], delimiter: "/", rawName: "Clients/Trash"),
                       IMAPListEntry(flags: [], delimiter: "/", rawName: "Corbeille")]
        let initial = try await store.replaceMailboxes(account: "account", with: entries)
        XCTAssertTrue(initial.allSatisfy { $0.role == .other })
        let chosen = try await store.replaceMailboxes(account: "account", with: entries, roles: ["Corbeille": .trash])
        XCTAssertEqual(chosen.first { $0.name == "Corbeille" }?.role, .trash)
        XCTAssertEqual(chosen.first { $0.name == "Clients/Trash" }?.role, .other)
    }
}
