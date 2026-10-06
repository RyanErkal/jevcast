import XCTest
@testable import LauncherCore

final class MailSearchCoverageTests: XCTestCase {
    private let account = NativeMailAccount(id: "coverage", provider: .yahoo, name: "Fixture", email: "fixture@example.com",
                                           imap: .init(host: "imap.example.com", port: 993, security: .tls),
                                           smtp: .init(host: "smtp.example.com", port: 465, security: .tls))

    func testSparseSearchHitDoesNotSkipNormalNewestOrOlderHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-search-coverage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeIMAPServer()
        for number in 1...6 { server.deliver(to: "Archive", subject: "Mail \(number)") }
        let store = try NativeMailStore(root: root)
        var policy = MailSyncPolicy()
        policy.firstOther = 2; policy.olderBatch = 2; policy.searchBatch = 1
        let sync = MailAccountSync(account: account, store: store, policy: policy, credential: { .password("app-password") }, transport: server.factory)
        await sync.pass(.everything)
        let boxes = try await store.mailboxes(account: account.id)
        let box = try XCTUnwrap(boxes.first { $0.name == "Archive" })
        let page = try await sync.search(mailboxIDs: [box.rowID], text: "", cursors: [box.rowID: 2], validities: [box.rowID: 1001], limit: 1)
        XCTAssertEqual(page.rowIDs.count, 1)
        let searchOnly = try await store.mailbox(box.rowID)
        XCTAssertNil(searchOnly?.uidNext)
        XCTAssertNil(searchOnly?.historyFloorUID)
        await sync.pass(.init(mailboxes: [box.rowID]))
        let initial = try await store.uidPage(box.rowID)
        XCTAssertEqual(initial, [2, 5, 6])
        let firstOlder = try await sync.loadOlder(box.rowID)
        XCTAssertEqual(firstOlder, true)
        let middle = try await store.uidPage(box.rowID)
        XCTAssertEqual(middle, [2, 3, 4, 5, 6])
        _ = try await sync.loadOlder(box.rowID)
        let complete = try await store.uidPage(box.rowID)
        XCTAssertEqual(complete, [1, 2, 3, 4, 5, 6])
        await sync.stop()
    }

    func testSearchContinuationRefusesMissingOrChangedValidity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-search-validity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeIMAPServer()
        for number in 1...3 { server.deliver(to: "Archive", subject: "Mail \(number)") }
        let store = try NativeMailStore(root: root)
        let sync = MailAccountSync(account: account, store: store, credential: { .password("app-password") }, transport: server.factory)
        await sync.pass(.everything)
        let boxes = try await store.mailboxes(account: account.id)
        let box = try XCTUnwrap(boxes.first { $0.name == "Archive" })
        let first = try await sync.search(mailboxIDs: [box.rowID], text: "", limit: 1)
        do {
            _ = try await sync.search(mailboxIDs: [box.rowID], text: "", cursors: first.cursors)
            XCTFail("Cursor-only continuation must fail")
        } catch {
            guard let mailError = error as? MailError, case .unexpected = mailError else { return XCTFail("Unexpected error: \(error)") }
        }
        server.lock.withLock { server.mailbox("Archive")?.uidValidity += 1 }
        do {
            _ = try await sync.search(mailboxIDs: [box.rowID], text: "", cursors: first.cursors, validities: first.validities)
            XCTFail("Changed UIDVALIDITY must fail")
        } catch {
            XCTAssertEqual(error as? MailError, .uidValidityChanged(mailbox: "Archive"))
        }
        await sync.stop()
    }

    func testLimitedServerCannotClaimCompleteOrDeleteHiddenCachedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-search-limited-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeIMAPServer()
        server.capabilities.append("MESSAGELIMIT=2")
        server.visibleLimit = 2; server.messageLimit = 2
        for number in 1...5 { server.deliver(to: "INBOX", subject: "Mail \(number)") }
        let store = try NativeMailStore(root: root)
        let sync = MailAccountSync(account: account, store: store, credential: { .password("app-password") }, transport: server.factory)
        await sync.pass(.everything)
        let boxes = try await store.mailboxes(account: account.id)
        let box = try XCTUnwrap(boxes.first { $0.name == "INBOX" })
        XCTAssertFalse(box.complete)
        var historic = SyncedMessage(uid: 1, date: Date(timeIntervalSince1970: 1))
        historic.subject = "Mail 1"
        try await store.upsert([historic], into: box.rowID)
        await sync.pass(.everything)
        let cached = try await store.rowID(uid: 1, in: box.rowID)
        XCTAssertNotNil(cached, "Hidden history must not be treated as deleted")
        let page = try await sync.search(mailboxIDs: [box.rowID], text: "")
        XCTAssertEqual(page.cursors[box.rowID], 0)
        XCTAssertFalse(page.complete)
        let repeated = try await sync.search(mailboxIDs: [box.rowID], text: "", cursors: page.cursors, validities: page.validities)
        XCTAssertFalse(repeated.complete)
        do {
            _ = try await sync.loadOlder(box.rowID)
            XCTFail("Limited history must require review")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("limited recent view"))
        }
        await sync.stop()
    }
}
