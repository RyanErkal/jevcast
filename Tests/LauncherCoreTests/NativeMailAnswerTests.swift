import XCTest
@testable import LauncherCore

/// Replies, forwards, permanent deletes, Empty, and server counts against the fake servers.
final class NativeMailAnswerTests: XCTestCase {
    private var root: URL!
    private var server: FakeIMAPServer!
    private var smtp: FakeSMTPServer!
    private var store: NativeMailStore!
    private var reader: MailDatabase!

    private let account = NativeMailAccount(id: "acct-1", provider: .yahoo, name: "Me", email: "me@yahoo.ie",
                                            imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
                                            smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-answer-" + UUID().uuidString, isDirectory: true)
        server = FakeIMAPServer(mailboxes: [("INBOX", []), ("Archive", ["\\Archive"]), ("Sent", ["\\Sent"]), ("Trash", ["\\Trash"]), ("Junk", ["\\Junk"])])
        smtp = FakeSMTPServer()
        store = try NativeMailStore(root: root)
        reader = try MailDatabase(path: NativeMailStore.indexPath(root: root))
    }

    override func tearDownWithError() throws {
        reader = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine() -> NativeMailEngine {
        let imap = server!, smtp = smtp!
        return NativeMailEngine(store: store, credential: { _ in .password("app-password") },
                                transport: { host, _, _ in host.hasPrefix("smtp") ? smtp.connect() : imap.connect() })
    }

    private func subjects(_ mailbox: String) throws -> [String] {
        try reader.rows("""
            SELECT s.subject FROM messages m JOIN subjects s ON s.ROWID = m.subject JOIN mailboxes b ON b.ROWID = m.mailbox
            WHERE b.name = ? AND m.deleted = 0 ORDER BY m.remote_uid
            """, [.text(mailbox)]).compactMap { $0.first?.text }
    }

    private func row(_ subject: String) throws -> Int64 {
        try XCTUnwrap(reader.rows("SELECT m.ROWID FROM messages m JOIN subjects s ON s.ROWID = m.subject WHERE s.subject = ?", [.text(subject)]).first?.first?.int)
    }

    private func mailboxRow(_ name: String) throws -> Int64 {
        try XCTUnwrap(reader.rows("SELECT ROWID FROM mailboxes WHERE name = ?", [.text(name)]).first?.first?.int)
    }

    private func waitUntil(_ what: String, _ condition: () throws -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(what)")
    }

    private func started(_ wanted: [String] = ["INBOX"]) async throws -> NativeMailEngine {
        let engine = makeEngine()
        await engine.setAccounts([account])
        try await waitUntil("the first sync") { try self.reader.rows("SELECT COUNT(*) FROM mailboxes").first?.first?.int ?? 0 > 0 }
        for name in wanted where name != "INBOX" { await engine.sync(MailSyncRequest(mailboxes: [try mailboxRow(name)])) }
        return engine
    }

    /// Yahoo files every message sent through its SMTP in Sent, so a copy from Jevcast would be a second one.
    func testYahooAccountsDoNotAddASecondSentCopy() {
        XCTAssertFalse(account.savesSentCopy)
        XCTAssertTrue(MailProvider.yahoo.serverSavesSent)
        XCTAssertFalse(MailProvider.icloud.serverSavesSent)
    }

    // MARK: Replies and forwards

    func testReplySendsTheComposerFieldsWithBccAndCanLeaveOutTheQuote() async throws {
        server.deliver(to: "INBOX", subject: "Plans", from: "Sam <sam@example.com>", body: "Friday?", messageID: "<p1@example.com>")
        let engine = try await started()
        try await waitUntil("the message") { try self.subjects("INBOX") == ["Plans"] }
        let recipients = NativeMailEngine.Recipients(to: [MailContact(name: "Ann Lee", address: "ann@example.com")],
                                                     cc: [MailContact(address: "bob@example.com")], bcc: [MailContact(address: "carl@example.com")])
        try await engine.reply(to: try row("Plans"), text: "Yes.", all: false, from: account.id, recipients: recipients, subject: "Re: Friday plans", quote: false)
        let delivery = try XCTUnwrap(smtp.delivered.last)
        XCTAssertEqual(Set(delivery.recipients), ["ann@example.com", "bob@example.com", "carl@example.com"])
        let sent = try XCTUnwrap(MIMEMessage.parse(delivery.data))
        XCTAssertEqual(sent.header("Subject"), "Re: Friday plans")
        XCTAssertEqual(sent.header("To"), "Ann Lee <ann@example.com>")
        XCTAssertNil(sent.header("Bcc"), "Bcc never appears in the headers")
        XCTAssertEqual(sent.header("In-Reply-To"), "<p1@example.com>")
        XCTAssertFalse(sent.plainText?.contains("wrote:") ?? true)
        XCTAssertFalse(sent.html?.contains("blockquote") ?? true)
        await engine.stopAll()
    }

    func testReplyQuoteLooksLikeAppleMail() async throws {
        server.deliver(to: "INBOX", subject: "Leads", from: "Bodhi <bodhi@example.com>", body: "Stop letting leads die.", messageID: "<l1@example.com>")
        let engine = try await started()
        try await waitUntil("the message") { try self.subjects("INBOX") == ["Leads"] }
        try await engine.reply(to: try row("Leads"), text: "Thanks.", all: false, from: account.id)
        let sent = try XCTUnwrap(smtp.delivered.last.flatMap { MIMEMessage.parse($0.data) })
        let html = try XCTUnwrap(sent.html)
        XCTAssertTrue(html.contains(#"<blockquote type="cite""#))
        let attribution = try XCTUnwrap(html.range(of: "wrote:"))
        XCTAssertLessThan(try XCTUnwrap(html.range(of: "<blockquote")).lowerBound, attribution.lowerBound, "The attribution sits inside the quote")
        XCTAssertTrue(html.contains("Bodhi &lt;bodhi@example.com&gt; wrote:"))
        let plain = (sent.plainText ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(plain.contains("Bodhi <bodhi@example.com> wrote:\n\n> Stop letting leads die."), plain)
        await engine.stopAll()
    }

    func testReplyAfterTheOriginalMovedUsesTheCopyKeptWithTheDraft() async throws {
        server.deliver(to: "INBOX", subject: "Moved", from: "Sam <sam@example.com>", body: "Original text", messageID: "<m1@example.com>")
        let engine = try await started()
        try await waitUntil("the message") { try self.subjects("INBOX") == ["Moved"] }
        let original = try row("Moved")
        try await engine.fetchBody(original)
        let raw = try await store.storedBody(original)
        let saved = try XCTUnwrap(raw.flatMap(MIMEMessage.parse))
        try await engine.move(original, to: try mailboxRow("Archive"))
        try await engine.reply(to: original, text: "Got it.", all: false, from: account.id, expectedMessageID: "<m1@example.com>",
                               saved: saved, savedDate: Date(timeIntervalSince1970: 1_790_000_000))
        let sent = try XCTUnwrap(smtp.delivered.last.flatMap { MIMEMessage.parse($0.data) })
        XCTAssertEqual(sent.header("In-Reply-To"), "<m1@example.com>")
        XCTAssertTrue(sent.plainText?.contains("> Original text") ?? false)
        await engine.stopAll()
    }

    func testForwardCarriesEachAttachmentAndTheOriginalHeaders() async throws {
        let raw = """
        From: Sam <sam@example.com>\r
        To: me@yahoo.ie\r
        Subject: Report\r
        Message-ID: <r1@example.com>\r
        Date: Tue, 29 Sep 2026 06:00:00 +0000\r
        Content-Type: multipart/mixed; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        See attached.\r
        --b1\r
        Content-Type: application/pdf; name="report.pdf"\r
        Content-Disposition: attachment; filename="report.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0xLjQK\r
        --b1--\r

        """
        server.deliverRaw(to: "INBOX", raw)
        let engine = try await started()
        try await waitUntil("the message") { try self.subjects("INBOX") == ["Report"] }
        try await engine.forward(try row("Report"), text: "FYI", to: ["ann@example.com"], from: account.id)
        let sent = try XCTUnwrap(smtp.delivered.last.flatMap { MIMEMessage.parse($0.data) })
        XCTAssertEqual(sent.attachments.map(\.name), ["report.pdf"], "The file goes as itself, not inside a forwarded .eml")
        XCTAssertEqual(MIMEMessage.files(try XCTUnwrap(smtp.delivered.last?.data)).first?.data, Data("%PDF-1.4\n".utf8))
        let html = try XCTUnwrap(sent.html)
        XCTAssertTrue(html.contains("Begin forwarded message:"))
        XCTAssertTrue(html.contains("<b>From:</b> Sam &lt;sam@example.com&gt;"))
        XCTAssertTrue(html.contains("<b>Subject:</b> Report"))
        await engine.stopAll()
    }

    func testForwardKeepsCapturedAttachmentBytesAfterOriginalRemoval() async throws {
        var original = OutgoingMessage(from: .init(address: "sam@example.com"), to: [.init(address: account.email)], subject: "Saved forward", body: "Original text")
        let bytes = Data([0, 255, 13, 10, 42])
        original.attachments = [.init(filename: "saved.bin", mimeType: "application/octet-stream", data: bytes)]
        let raw = MailComposer.render(original)
        server.deliverRaw(to: "INBOX", String(decoding: raw, as: UTF8.self))
        let engine = try await started()
        try await waitUntil("the forward source") { try self.subjects("INBOX") == ["Saved forward"] }
        let sourceRow = try row("Saved forward")
        let saved = try XCTUnwrap(MIMEMessage.parse(raw))
        try await engine.move(sourceRow, to: try mailboxRow("Archive"))
        let removed = try await store.location(of: sourceRow)
        XCTAssertNil(removed)
        try await engine.forward(sourceRow, text: "FYI", to: ["ann@example.com"], from: account.id,
                                 expectedMessageID: saved.header("Message-ID"), saved: saved,
                                 savedDate: Date(timeIntervalSince1970: 1_790_000_000), savedAttachments: original.attachments)
        let delivery = try XCTUnwrap(smtp.delivered.last)
        XCTAssertEqual(MIMEMessage.files(delivery.data).first?.data, bytes)
        XCTAssertEqual(MIMEMessage.files(delivery.data).first?.name, "saved.bin")
        await engine.stopAll()
    }

    // MARK: Trash and Junk

    func testDeleteInTrashRemovesOnlyThatMessageAndOnlyWhenAsked() async throws {
        server.deliver(to: "INBOX", subject: "Old news")
        // Another program marked this one deleted; a targeted UID EXPUNGE must leave it.
        let other = server.deliver(to: "Trash", subject: "Marked elsewhere", flags: ["\\Deleted"])
        let engine = try await started()
        try await waitUntil("the message") { try self.subjects("INBOX") == ["Old news"] }
        try await engine.delete(try row("Old news"))
        try await waitUntil("the trashed copy") { try self.subjects("Trash").contains("Old news") }
        let trashed = try row("Old news")
        do { try await engine.delete(trashed); XCTFail("A message in Trash is removed only when asked") }
        catch MailError.notFound(let reason) { XCTAssertTrue(reason.contains("already in Trash")) }
        XCTAssertEqual(server.mailbox("Trash")!.messages.count, 2)
        try await engine.delete(trashed, permanently: true)
        XCTAssertEqual(server.mailbox("Trash")!.messages.map(\.uid), [other])
        XCTAssertFalse(try subjects("Trash").contains("Old news"))
        XCTAssertEqual(server.commands("EXPUNGE"), 0, "Never a mailbox-wide EXPUNGE")
        await engine.stopAll()
    }

    func testEmptyRemovesExactlyTheMessagesCounted() async throws {
        for n in 1...5 { server.deliver(to: "Trash", subject: "Bin \(n)") }
        server.deliver(to: "Junk", subject: "Spam")
        let engine = try await started(["INBOX", "Trash", "Junk"])
        let trash = try mailboxRow("Trash")
        let counted = try await engine.contents(of: trash)
        XCTAssertEqual(counted.uids.count, 5)
        let late = server.deliver(to: "Trash", subject: "Arrived after the count")
        try await engine.empty(trash, uids: counted.uids, validity: counted.validity)
        XCTAssertEqual(server.mailbox("Trash")!.messages.map(\.uid), [late])
        let junk = try mailboxRow("Junk")
        let spam = try await engine.contents(of: junk)
        try await engine.empty(junk, uids: spam.uids, validity: spam.validity)
        XCTAssertTrue(server.mailbox("Junk")!.messages.isEmpty)
        do { _ = try await engine.contents(of: try mailboxRow("INBOX")); XCTFail("Only Trash and Junk can be emptied") }
        catch MailError.notFound {}
        XCTAssertEqual(server.commands("EXPUNGE"), 0)
        await engine.stopAll()
    }

    func testEmptyStaysInsideTheMessageLimit() async throws {
        server.capabilities += ["MESSAGELIMIT=2"]
        server.messageLimit = 2
        for n in 1...5 { server.deliver(to: "Trash", subject: "Bin \(n)") }
        let engine = try await started(["INBOX", "Trash"])
        let trash = try mailboxRow("Trash")
        let counted = try await engine.contents(of: trash)
        XCTAssertEqual(counted.uids.count, 5)
        try await engine.empty(trash, uids: counted.uids, validity: counted.validity)
        XCTAssertTrue(server.mailbox("Trash")!.messages.isEmpty)
        XCTAssertEqual(server.commands("UID EXPUNGE"), 3, "Five messages in batches of two")
        await engine.stopAll()
    }

    // MARK: Counts

    func testServerCountsCoverMailNotOnThisMac() async throws {
        server.capabilities.append("LIST-STATUS")
        for n in 1...4 { server.deliver(to: "Trash", subject: "Bin \(n)") }
        server.deliver(to: "INBOX", subject: "Unread")
        server.deliver(to: "INBOX", subject: "Read", flags: ["\\Seen"])
        let engine = try await started()
        try await waitUntil("server counts") {
            try self.reader.rows("SELECT server_total FROM mailboxes WHERE name = 'Trash'").first?.first?.int == 4
        }
        XCTAssertEqual(try reader.rows("SELECT server_total, server_unread FROM mailboxes WHERE name = 'INBOX'").first?.compactMap(\.int), [2, 1])
        XCTAssertEqual(try subjects("Trash"), [], "Counted, not downloaded")
        XCTAssertEqual(server.commands("STATUS"), 0, "One LIST with LIST-STATUS")
        await engine.stopAll()
    }
}
