import XCTest
@testable import LauncherCore

/// Sync, changes, and sending against the fake IMAP and SMTP servers, with a real store on disk.
final class NativeMailSyncTests: XCTestCase {
    private var root: URL!
    private var server: FakeIMAPServer!
    private var smtp: FakeSMTPServer!
    private var store: NativeMailStore!
    private var reader: MailDatabase!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-native-" + UUID().uuidString, isDirectory: true)
        server = FakeIMAPServer()
        smtp = FakeSMTPServer()
        store = try NativeMailStore(root: root)
        reader = try MailDatabase(path: NativeMailStore.indexPath(root: root))
    }

    override func tearDownWithError() throws {
        reader = nil
        try? FileManager.default.removeItem(at: root)
    }

    private let account = NativeMailAccount(id: "acct-1", provider: .yahoo, name: "Me", email: "me@yahoo.ie",
                                            imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
                                            smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls), savesSentCopy: true)

    private var transport: IMAPClient.TransportFactory {
        let imap = server!, smtp = smtp!
        return { host, _, _ in host.hasPrefix("smtp") ? smtp.connect() : imap.connect() }
    }

    private func makeSync(_ policy: MailSyncPolicy = MailSyncPolicy(), password: String = "app-password") -> MailAccountSync {
        MailAccountSync(account: account, store: store, policy: policy, credential: { .password(password) }, transport: transport)
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

    private func value(_ sql: String, _ arguments: [MailDatabase.Value] = []) throws -> Int64? {
        try reader.rows(sql, arguments).first?.first?.int
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(what)")
    }

    private func pass(_ sync: MailAccountSync, _ request: MailSyncRequest) async {
        if case .done = await sync.pass(request) { return }
        let state = await sync.state
        XCTFail("The sync pass failed: \(state)")
    }

    // MARK: Sync

    func testFirstSyncTakesOnlyTheNewestAndOlderMailWaitsForTheList() async throws {
        for n in 1...5 { server.deliver(to: "INBOX", subject: "Inbox \(n)", date: Date(timeIntervalSince1970: 1_790_000_000 + Double(n))) }
        server.deliver(to: "Archive", subject: "Kept", flags: ["\\Seen"])
        var policy = MailSyncPolicy()
        policy.firstInbox = 3; policy.headerBatch = 2; policy.olderBatch = 1
        let sync = makeSync(policy)
        await pass(sync, .everything)
        await pass(sync, .everything)
        // Only the newest three, however many passes run. A folder not yet opened costs nothing.
        XCTAssertEqual(try subjects("INBOX"), ["Inbox 3", "Inbox 4", "Inbox 5"])
        XCTAssertEqual(try subjects("Archive"), [])
        XCTAssertEqual(try value("SELECT unread_count FROM mailboxes WHERE name = 'INBOX'"), 3)
        XCTAssertEqual(try value("SELECT complete FROM mailboxes WHERE name = 'INBOX'"), 0)
        // Older mail comes one batch at a time when the list asks.
        let inbox = try XCTUnwrap(value("SELECT ROWID FROM mailboxes WHERE name = 'INBOX'"))
        let firstStep = try await sync.loadOlder(inbox)
        XCTAssertEqual(firstStep, true)
        XCTAssertEqual(try subjects("INBOX"), ["Inbox 2", "Inbox 3", "Inbox 4", "Inbox 5"])
        let lastStep = try await sync.loadOlder(inbox)
        XCTAssertEqual(lastStep, false)
        XCTAssertEqual(try subjects("INBOX"), ["Inbox 1", "Inbox 2", "Inbox 3", "Inbox 4", "Inbox 5"])
        XCTAssertEqual(try value("SELECT complete FROM mailboxes WHERE name = 'INBOX'"), 1)
        let afterEnd = try await sync.loadOlder(inbox)
        XCTAssertEqual(afterEnd, false)
        // Opening a folder reads it, and later passes keep it current.
        let archive = try XCTUnwrap(value("SELECT ROWID FROM mailboxes WHERE name = 'Archive'"))
        await pass(sync, MailSyncRequest(mailboxes: [archive]))
        XCTAssertEqual(try subjects("Archive"), ["Kept"])
        XCTAssertEqual(try value("SELECT unread_count FROM mailboxes WHERE name = 'Archive'"), 0)
        server.deliver(to: "Archive", subject: "Later")
        await pass(sync, .everything)
        XCTAssertEqual(try subjects("Archive"), ["Kept", "Later"])
        // Roles come from the server's special-use flags.
        XCTAssertEqual(try reader.rows("SELECT role FROM mailboxes WHERE name = 'Archive'").first?.first?.text, "archive")
        XCTAssertEqual(try reader.rows("SELECT url FROM mailboxes WHERE name = 'INBOX'").first?.first?.text, "imap://acct-1/INBOX")
        // Bodies of the newest inbox messages are read ahead.
        XCTAssertGreaterThan(try value("SELECT COUNT(*) FROM messages WHERE has_body = 1") ?? 0, 0)
        await sync.stop()
    }

    func testNewMailFlagChangesAndRemovalsArrive() async throws {
        let first = server.deliver(to: "INBOX", subject: "One")
        let second = server.deliver(to: "INBOX", subject: "Two")
        let sync = makeSync()
        await pass(sync, .everything)
        server.deliver(to: "INBOX", subject: "Three")
        server.setFlags(["\\Seen", "\\Flagged"], uid: first, in: "INBOX")
        server.expungeExternally(uid: second, in: "INBOX")
        await pass(sync, .inboxOnly)
        XCTAssertEqual(try subjects("INBOX"), ["One", "Three"])
        let one = try row("One")
        XCTAssertEqual(try value("SELECT read FROM messages WHERE ROWID = ?", [.int(one)]), 1)
        XCTAssertEqual(try value("SELECT flagged FROM messages WHERE ROWID = ?", [.int(one)]), 1)
        await sync.stop()
    }

    func testFlagChangesWithoutCONDSTORE() async throws {
        server.capabilities.removeAll { $0 == "CONDSTORE" || $0 == "ESEARCH" }
        let uid = server.deliver(to: "INBOX", subject: "One")
        let sync = makeSync()
        await pass(sync, .everything)
        server.setFlags(["\\Seen"], uid: uid, in: "INBOX")
        await pass(sync, .inboxOnly)
        XCTAssertEqual(try value("SELECT read FROM messages WHERE ROWID = ?", [.int(try row("One"))]), 1)
        await sync.stop()
    }

    /// Yahoo shows only the newest thousand messages of a folder unless the client turns on UIDONLY.
    func testUIDOnlyReachesMailBeyondTheServersDefaultView() async throws {
        server.visibleLimit = 3
        server.capabilities.append("UIDONLY")
        for n in 1...6 { server.deliver(to: "INBOX", subject: "Mail \(n)") }
        var policy = MailSyncPolicy()
        policy.firstInbox = 4; policy.olderBatch = 10
        let sync = makeSync(policy)
        await pass(sync, .everything)
        let older = try await sync.loadOlder(try XCTUnwrap(value("SELECT ROWID FROM mailboxes WHERE name = 'INBOX'")))
        XCTAssertEqual(older, false)
        XCTAssertEqual(try subjects("INBOX"), (1...6).map { "Mail \($0)" })
        let client = await sync.syncClient
        let uidOnly = await client.uidOnly
        XCTAssertTrue(uidOnly)
        // New mail and changes still work with UIDs only.
        let uid = server.deliver(to: "INBOX", subject: "Mail 7")
        server.setFlags(["\\Seen"], uid: 1, in: "INBOX")
        await pass(sync, .inboxOnly)
        XCTAssertEqual(try subjects("INBOX").last, "Mail 7")
        XCTAssertEqual(try value("SELECT read FROM messages WHERE ROWID = ?", [.int(try row("Mail 1"))]), 1)
        XCTAssertEqual(uid, 7)
        XCTAssertEqual(server.commands("FETCH"), 0, "No message numbers with UIDONLY")
        await sync.stop()
    }

    /// Yahoo refuses a UID SEARCH that would find more than MESSAGELIMIT messages, and reports a
    /// mod-sequence without CONDSTORE. Sync must read a large, sparse folder in bounded steps.
    func testMessageLimitIsKeptInALargeSparseFolder() async throws {
        server.capabilities = ["IMAP4rev1", "LITERAL+", "UIDPLUS", "MOVE", "IDLE", "AUTH=PLAIN", "SASL-IR", "ENABLE", "UIDONLY", "MESSAGELIMIT=40"]
        server.messageLimit = 40
        server.visibleLimit = 40
        server.modSeqWithoutCondstore = true
        // Older mail is dense; newer mail has gaps, as after years of deletes and moves.
        var uids: [Int: UInt32] = [:]
        for n in 1...300 {
            uids[n] = server.deliver(to: "INBOX", subject: "Mail \(n)")
            if n > 150 { server.skipUIDs(9, in: "INBOX") }
        }
        var policy = MailSyncPolicy()
        policy.firstInbox = 100; policy.checkBatch = 30; policy.olderBatch = 80
        let sync = makeSync(policy)
        await pass(sync, .everything)
        XCTAssertEqual(try subjects("INBOX"), (201...300).map { "Mail \($0)" })
        XCTAssertFalse(server.searches.contains { $0.uppercased() == "ALL" }, "Never one search over the whole folder")
        // New mail, flag changes, and removals still arrive, without CHANGEDSINCE.
        server.deliver(to: "INBOX", subject: "Mail 301")
        server.setFlags(["\\Seen"], uid: try XCTUnwrap(uids[250]), in: "INBOX")
        server.expungeExternally(uid: try XCTUnwrap(uids[260]), in: "INBOX")
        await pass(sync, .inboxOnly)
        let current = try subjects("INBOX")
        XCTAssertEqual(current.count, 100)
        XCTAssertEqual(current.last, "Mail 301")
        XCTAssertFalse(current.contains("Mail 260"))
        XCTAssertEqual(try value("SELECT read FROM messages WHERE ROWID = ?", [.int(try row("Mail 250"))]), 1)
        // Older mail reaches the dense part; ranges the server refuses are halved.
        let inbox = try XCTUnwrap(value("SELECT ROWID FROM mailboxes WHERE name = 'INBOX'"))
        let more = try await sync.loadOlder(inbox)
        XCTAssertEqual(more, true)
        let loaded = try subjects("INBOX")
        XCTAssertEqual(loaded.count, 180)
        XCTAssertTrue(loaded.contains("Mail 121"))
        XCTAssertFalse(loaded.contains("Mail 120"))
        XCTAssertGreaterThan(server.refusedSearches, 0, "The test must reach a refused range")
        await sync.stop()
    }

    func testWithoutUIDOnlyOnlyTheServersViewSyncs() async throws {
        server.visibleLimit = 3
        for n in 1...6 { server.deliver(to: "INBOX", subject: "Mail \(n)") }
        let sync = makeSync()
        await pass(sync, .everything)
        XCTAssertEqual(try subjects("INBOX"), ["Mail 4", "Mail 5", "Mail 6"])
        await sync.stop()
    }

    func testRenumberedMailboxIsReadAgain() async throws {
        server.deliver(to: "INBOX", subject: "Before")
        let sync = makeSync()
        await pass(sync, .everything)
        let oldRow = try row("Before")
        server.mailbox("INBOX")!.uidValidity = 5000
        await pass(sync, .inboxOnly)
        await pass(sync, .inboxOnly)
        XCTAssertEqual(try subjects("INBOX"), ["Before"])
        XCTAssertNotEqual(try row("Before"), oldRow)
        XCTAssertEqual(try value("SELECT uid_validity FROM mailboxes WHERE name = 'INBOX'"), 5000)
        await sync.stop()
    }

    func testChangeAfterRenumberingUsesTheNewNumbers() async throws {
        let uid = server.deliver(to: "INBOX", subject: "Keep")
        let engine = makeEngine()
        await engine.setAccounts([account])
        try await waitUntil("the first sync") { try self.subjects("INBOX") == ["Keep"] }
        // The action connection selects INBOX with the first numbering.
        try await engine.setFlagged(try row("Keep"), true)
        server.mailbox("INBOX")!.uidValidity = 7000
        await engine.sync(.inboxOnly)
        try await waitUntil("the reset") { try self.value("SELECT uid_validity FROM mailboxes WHERE name = 'INBOX'") == 7000 && self.subjects("INBOX") == ["Keep"] }
        try await engine.setRead(try row("Keep"), true)
        XCTAssertTrue(server.mailbox("INBOX")!.messages.first { $0.uid == uid }!.flags.contains("\\Seen"))
        await engine.stopAll()
    }

    func testWrongPasswordStopsAndSaysSo() async throws {
        let sync = makeSync(password: "wrong")
        guard case .signIn = await sync.pass(.everything) else { return XCTFail("A refused sign-in must stop sync") }
        guard case .failed(let text, let signIn) = await sync.state else { return XCTFail() }
        XCTAssertTrue(signIn)
        XCTAssertTrue(text.contains("app password"))
        await sync.stop()
    }

    // MARK: Changes through the engine

    private func makeEngine() -> NativeMailEngine {
        NativeMailEngine(store: store, credential: { _ in .password("app-password") }, transport: transport)
    }

    func testChangesReachTheServer() async throws {
        let readUID = server.deliver(to: "INBOX", subject: "Read me")
        server.deliver(to: "INBOX", subject: "Archive me")
        server.deliver(to: "INBOX", subject: "Delete me")
        let engine = makeEngine()
        await engine.setAccounts([account])
        try await waitUntil("the first sync") { try self.subjects("INBOX").count == 3 }

        try await engine.setRead(try row("Read me"), true)
        XCTAssertTrue(server.mailbox("INBOX")!.messages.first { $0.uid == readUID }!.flags.contains("\\Seen"))
        XCTAssertEqual(try value("SELECT read FROM messages WHERE ROWID = ?", [.int(try row("Read me"))]), 1)
        try await engine.setFlagged(try row("Read me"), true)
        XCTAssertTrue(server.mailbox("INBOX")!.messages.first { $0.uid == readUID }!.flags.contains("\\Flagged"))

        let archive = try XCTUnwrap(value("SELECT ROWID FROM mailboxes WHERE name = 'Archive'"))
        try await engine.move(try row("Archive me"), to: archive)
        XCTAssertEqual(server.mailbox("Archive")!.messages.count, 1)
        try await waitUntil("the archived copy") { try self.subjects("Archive") == ["Archive me"] }
        XCTAssertEqual(try subjects("INBOX"), ["Read me", "Delete me"])

        try await engine.delete(try row("Delete me"))
        XCTAssertEqual(server.mailbox("Trash")!.messages.count, 1)
        XCTAssertEqual(try subjects("INBOX"), ["Read me"])
        try await waitUntil("the trashed copy") { try self.subjects("Trash") == ["Delete me"] }
        do { try await engine.delete(try row("Delete me")); XCTFail("Trash must never be purged") }
        catch MailError.notFound(let reason) { XCTAssertTrue(reason.contains("already in Trash")) }
        XCTAssertEqual(server.mailbox("Trash")!.messages.count, 1)
        await engine.stopAll()
    }

    func testBodiesRepliesAndForwards() async throws {
        server.deliver(to: "INBOX", subject: "Question", from: "Sam <sam@example.com>", body: "Are you free?", messageID: "<q1@example.com>")
        let engine = makeEngine()
        await engine.setAccounts([account])
        try await waitUntil("the first sync") { try self.subjects("INBOX") == ["Question"] }
        let question = try row("Question")
        let fetched = try await engine.fetchBody(question)
        XCTAssertTrue(fetched)
        let stored = try await store.storedBody(question)
        XCTAssertEqual(stored.flatMap(MIMEMessage.parse)?.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "Are you free?")
        XCTAssertEqual(try reader.rows("SELECT s.summary FROM messages m JOIN summaries s ON s.ROWID = m.summary WHERE m.ROWID = ?", [.int(question)]).first?.first?.text,
                       "Are you free?")

        try await engine.reply(to: question, text: "Yes, Friday.", all: false, from: account.id)
        let reply = try XCTUnwrap(smtp.delivered.last)
        XCTAssertEqual(reply.recipients, ["sam@example.com"])
        let sent = try XCTUnwrap(MIMEMessage.parse(reply.data))
        XCTAssertEqual(sent.header("Subject"), "Re: Question")
        XCTAssertEqual(sent.header("In-Reply-To"), "<q1@example.com>")
        XCTAssertTrue(sent.plainText?.contains("> Are you free?") == true)
        XCTAssertEqual(server.mailbox("Sent")!.messages.count, 1, "An account set to save a copy gets one in Sent")
        XCTAssertTrue(server.mailbox("INBOX")!.messages[0].flags.contains("\\Answered"))

        try await engine.forward(question, text: "FYI", to: ["ann@example.com"], from: account.id)
        let forward = try XCTUnwrap(smtp.delivered.last.flatMap { MIMEMessage.parse($0.data) })
        XCTAssertEqual(forward.header("Subject"), "Fwd: Question")
        XCTAssertTrue(forward.plainText?.contains("Begin forwarded message:") == true)

        try await engine.send(from: account.id, to: ["bob@example.com"], cc: [], subject: "New", body: "Hello Bob")
        XCTAssertEqual(smtp.delivered.last?.recipients, ["bob@example.com"])
        XCTAssertEqual(smtp.delivered.count, 3)
        await engine.stopAll()
    }

    func testExplicitAccountReplyKeepsThreadHeadersAndInvalidAccountDoesNotSend() async throws {
        server.deliver(to: "INBOX", subject: "Question", from: "Sam <sam@example.com>", body: "Are you free?", messageID: "<q1@example.com>")
        var other = account
        other.id = "acct-2"; other.email = "other@example.com"; other.savesSentCopy = false
        let engine = makeEngine()
        await engine.setAccounts([account, other])
        try await waitUntil("both accounts") { try self.value("SELECT COUNT(*) FROM messages") == 2 }
        let question = try XCTUnwrap(reader.rows("SELECT m.ROWID FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox WHERE b.account = ?", [.text(account.id)]).first?.first?.int)
        do {
            try await engine.send(from: "missing", to: ["sam@example.com"], cc: [], subject: "Do not send", body: "Keep")
            XCTFail("An unavailable account must not fall back")
        } catch MailError.notFound {}
        XCTAssertTrue(smtp.delivered.isEmpty)
        try await engine.reply(to: question, text: "Friday works", all: false, from: other.id,
                               html: "<p><b>Friday works</b></p>", expectedMessageID: "<q1@example.com>")
        let reply = try XCTUnwrap(smtp.delivered.last.flatMap { MIMEMessage.parse($0.data) })
        XCTAssertEqual(MailAddress.list(reply.header("From") ?? "").first?.address, other.email)
        XCTAssertEqual(reply.header("In-Reply-To"), "<q1@example.com>")
        XCTAssertEqual(reply.header("References"), "<q1@example.com>")
        XCTAssertTrue(reply.html?.contains("<b>Friday works</b>") == true)
        await engine.stopAll()
    }

    func testRefusedSignInDoesNotRestartOnBackgroundRequests() async throws {
        var policy = MailSyncPolicy(); policy.periodic = 0.01
        let sync = makeSync(policy, password: "wrong")
        await sync.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .failed(_, signIn: true) = await sync.state { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .failed(_, signIn: true) = await sync.state else { return XCTFail("Sign-in must stop") }
        let attempts = server.commands("AUTHENTICATE") + server.commands("LOGIN")
        await sync.request(.everything); await sync.wake(); await sync.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(server.commands("AUTHENTICATE") + server.commands("LOGIN"), attempts)
        XCTAssertGreaterThan(attempts, 0)
        await sync.stop()
    }

    func testTemporaryCredentialFailureAllowsNextSyncPass() async throws {
        actor Credentials {
            var calls = 0
            func read() throws -> MailCredential {
                calls += 1
                if calls == 1 { throw MailOAuthError.temporarilyUnavailable }
                return .password("app-password")
            }
        }
        let credentials = Credentials()
        server.deliver(to: "INBOX", subject: "After provider recovery")
        let sync = MailAccountSync(account: account, store: store, credential: { try await credentials.read() }, transport: transport)
        guard case .failed = await sync.pass(.everything) else { return XCTFail("A temporary failure must remain retryable") }
        guard case .failed(_, signIn: false) = await sync.state else { return XCTFail("Do not ask the user to sign in again") }
        await pass(sync, .everything)
        XCTAssertEqual(try subjects("INBOX"), ["After provider recovery"])
        await sync.stop()
    }

    func testIdleBringsNewMailWithoutAsking() async throws {
        server.deliver(to: "INBOX", subject: "First")
        let engine = makeEngine()
        await engine.setAccounts([account])
        try await waitUntil("the first sync") { try self.subjects("INBOX") == ["First"] }
        try await waitUntil("IDLE") { self.server.commands("IDLE") > 0 }
        server.deliver(to: "INBOX", subject: "Pushed")
        try await waitUntil("the pushed message") { try self.subjects("INBOX") == ["First", "Pushed"] }
        await engine.stopAll()
    }

    func testRemovingAnAccountDeletesItsLocalData() async throws {
        server.deliver(to: "INBOX", subject: "Local")
        let engine = makeEngine()
        await engine.setAccounts([account])
        try await waitUntil("the first sync") { try self.subjects("INBOX") == ["Local"] }
        try await engine.removeData(for: account.id)
        XCTAssertEqual(try value("SELECT COUNT(*) FROM messages"), 0)
        XCTAssertEqual(try value("SELECT COUNT(*) FROM mailboxes"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(account.id).path))
        XCTAssertEqual(server.mailbox("INBOX")!.messages.count, 1, "The server keeps its mail")
        await engine.stopAll()
    }
}
