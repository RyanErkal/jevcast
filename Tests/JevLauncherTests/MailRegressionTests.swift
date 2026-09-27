import XCTest
import SQLite3
import LauncherCore
@testable import JevLauncher

final class MailRegressionTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-regression-" + UUID().uuidString).path
        try MailFixture.build(root: root, layout: .init(gmailInbox: 260, allMailOnly: 0, sent: 0, trash: 0, exchangeInbox: 0, projects: 0))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root)
    }

    private func write(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(MailStore.indexPath(root), &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteReader.Failure(text: String(cString: sqlite3_errmsg(db)))
        }
    }

    func testCanonicalCopiesAreChosenBeforeCursorAndLimit() throws {
        // Put all archive copies above all inbox copies. Page-local deduplication cannot work.
        try write("UPDATE messages SET date_received = date_received + 100000 WHERE mailbox = 2")
        var query = MailStore.Query(mailboxes: [1, 2], dedupe: true, preferred: [1])
        let first = try MailStore.page(root: root, query)
        XCTAssertEqual(first.messages.count, 200)
        XCTAssertTrue(first.messages.allSatisfy { $0.mailbox == 1 })
        query.before = first.last
        let second = try MailStore.page(root: root, query)
        XCTAssertEqual(second.messages.count, 60)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(Set((first.messages + second.messages).map(\.messageKey)).count, 260)
    }

    func testEmptyScopesNeverSearchOtherMailboxes() throws {
        try write("UPDATE messages SET flagged = 1, read = 0")
        for query in [MailStore.Query(mailboxes: [], unreadOnly: true), .init(mailboxes: [], flaggedOnly: true)] {
            XCTAssertTrue(try MailStore.page(root: root, query).messages.isEmpty)
        }
    }

    func testDifferentKeyNamespacesDoNotHideMessages() throws {
        try write("""
            DELETE FROM messages;
            INSERT INTO messages (ROWID, mailbox, date_received, deleted, read, flagged, global_message_id, message_id)
            VALUES (1, 1, 10, 0, 0, 0, 42, 100), (2, 1, 10, 0, 0, 0, 0, 42), (3, 1, 10, 0, 0, 0, 0, 0),
                   (4, 1, 10, 0, 0, 0, 0, -3);
            """)
        let messages = try MailStore.page(root: root, .init(mailboxes: [1], dedupe: true)).messages
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(Set(messages.map(\.messageKey)).count, 4)
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: [1], distinct: true), 4)
    }

    func testIndexReplacementReopensConnection() throws {
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: [1]), 260)
        let replacement = root + "/replacement"
        try MailFixture.build(root: replacement, layout: .init(gmailInbox: 1, allMailOnly: 0, sent: 0, trash: 0, exchangeInbox: 0, projects: 0))
        // Both fixtures have checkpointed WALs. Retain the old file for cleanup.
        try FileManager.default.moveItem(atPath: MailStore.indexPath(root), toPath: root + "/old-index")
        try FileManager.default.moveItem(atPath: MailStore.indexPath(replacement), toPath: MailStore.indexPath(root))
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: [1]), 1)
    }

    func testCancelledRunningSQLLeavesCachedStatementUsable() throws {
        let db = try MailStore.open(root)
        let sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < ?) SELECT sum(x) FROM n"
        var checks = 0
        XCTAssertThrowsError(try db.withStop({ checks += 1; return checks > 2 }) { try db.rows(sql, [.int(1_000_000)]) })
        XCTAssertGreaterThan(checks, 2)
        XCTAssertEqual(try db.rows(sql, [.int(3)]).first?.first?.int, 6)
        XCTAssertThrowsError(try db.rows("DELETE FROM messages"), "The production reader cannot write to the index.")
    }

    func testRefreshKeepsRowsLoadedAfterStateSnapshotAndUpdatesMailbox() {
        let old = message(1, box: 1, date: 10)
        let paged = message(2, box: 1, date: 9)
        let kept = MailModel.refreshed([old, paged], states: [1: .init(mailbox: 2, read: true, flagged: false)], requested: [1],
                                      query: .init(mailboxes: [1, 2]), selectedID: 1)
        XCTAssertEqual(kept.map(\.rowID), [1, 2])
        XCTAssertEqual(kept.first?.mailbox, 2)
        XCTAssertEqual(kept.first?.read, true)
    }

    func testMergeSortsPinnedSelectionAndReplacesCopy() {
        let pinned = message(1, box: 2, date: 1, key: "global:1")
        let next = message(2, box: 1, date: 5)
        let inbox = message(3, box: 1, date: 0, key: "global:1")
        let query = MailStore.Query(mailboxes: [1, 2], dedupe: true, preferred: [1])
        XCTAssertEqual(MailModel.merge([pinned], [next], query: query).map(\.rowID), [2, 1])
        XCTAssertEqual(MailModel.merge([pinned], [next, inbox], query: query).map(\.rowID), [2, 3])
    }

    func testHTMLRevisionIncludesSameLengthContentAndImages() {
        let a = MailHTMLView.DocumentKey(id: 1, html: "first", images: [:], remote: false, fitsWidth: true)
        let b = MailHTMLView.DocumentKey(id: 1, html: "other", images: [:], remote: false, fitsWidth: true)
        XCTAssertNotEqual(a, b)
        let c = MailHTMLView.DocumentKey(id: 1, html: "first", images: ["x": .init(mimeType: "image/png", data: Data([1]))], remote: false, fitsWidth: true)
        XCTAssertNotEqual(a, c)
    }

    @MainActor func testLauncherSelectionWaitsForInitialStatus() async throws {
        let model = makeModel()
        model.refreshStatus()
        XCTAssertTrue(model.open(2), "An opening selection is queued while access is checked.")
        try await wait { model.selectedID == 2 && model.place == .mailbox(2) && !model.isLoading }
        XCTAssertEqual(model.selected?.mailbox, 2)
    }

    func testInPlaceSchemaChangeRefreshesCachedColumns() throws {
        _ = try MailStore.page(root: root, .init(mailboxes: [1]))
        try write("ALTER TABLE messages DROP COLUMN read; UPDATE messages SET flags = 1")
        let page = try MailStore.page(root: root, .init(mailboxes: [1]))
        XCTAssertTrue(page.messages.allSatisfy(\.read))
    }

    @MainActor func testReloadDuringNextPageDoesNotBlockFuturePaging() async throws {
        let model = makeModel()
        model.refreshStatus()
        try await wait { model.messages.count == 200 && !model.isLoading }
        let selected = model.messages[100].rowID
        model.select(selected, byUser: false)
        let entered = expectation(description: "Index queue blocked")
        let release = DispatchSemaphore(value: 0)
        let fixtureRoot = root
        let blocker = Task.detached {
            try MailStore.withIndex(fixtureRoot) { _, _ in entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        }
        await fulfillment(of: [entered], timeout: 3)
        model.loadNextPage()
        model.reload(keepSelection: true)
        release.signal()
        _ = try await blocker.value
        try await wait { !model.isLoading }
        model.loadNextPage()
        try await wait { model.messages.count == 260 && !model.isLoading }
        XCTAssertEqual(model.selectedID, selected)
    }

    @MainActor func testRefreshOverTwoHundredRowsKeepsAllLoadedPagesAndSelection() async throws {
        let model = makeModel()
        model.refreshStatus()
        try await wait { model.messages.count == 200 && !model.isLoading }
        model.loadNextPage()
        try await wait { model.messages.count == 260 && !model.isLoading }
        let selected = try XCTUnwrap(model.messages.last?.rowID)
        model.select(selected, byUser: false)
        try write("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < 405)
            INSERT INTO messages (mailbox, date_received, deleted, read, flagged, global_message_id)
            SELECT 1, 1900000000 + x, 0, 1, 0, 2000000 + x FROM n;
            """)
        XCTAssertTrue(model.refresh())
        XCTAssertFalse(model.refresh(), "Overlapping refreshes are coalesced.")
        try await wait { !model.isLoading }
        XCTAssertEqual(model.messages.count, 665)
        XCTAssertEqual(model.selectedID, selected)
    }

    @MainActor func testLaterSelectionStaysSortedAfterReloadAndPaging() async throws {
        let model = makeModel()
        model.refreshStatus()
        try await wait { model.messages.count == 200 && !model.isLoading }
        model.loadNextPage()
        try await wait { model.messages.count == 260 && !model.isLoading }
        let id = try XCTUnwrap(model.messages.last?.rowID)
        model.select(id, byUser: false)
        model.reload(keepSelection: true)
        try await wait { !model.isLoading }
        XCTAssertEqual(model.selectedID, id)
        model.loadNextPage()
        try await wait { model.messages.count == 260 && !model.isLoading }
        XCTAssertEqual(model.messages.last?.rowID, id)
        XCTAssertEqual(model.selectedID, id)
        try write("DELETE FROM messages WHERE ROWID = \(id)")
        model.reload(keepSelection: true)
        try await wait { !model.isLoading }
        XCTAssertFalse(model.messages.contains { $0.rowID == id }, "A removed selected row must not be pinned forever.")
    }

    @MainActor func testNewSearchCannotAcceptAnOldPageDuringDebounce() async throws {
        let model = makeModel()
        model.refreshStatus()
        try await wait { model.messages.count == 200 && !model.isLoading }
        model.loadNextPage()
        model.search = "body123."
        try await wait { model.messages.count == 1 && !model.isLoading }
        let matches = try MailStore.messages(root: root, .init(mailboxes: [1], text: "body123."))
        XCTAssertEqual(model.messages.map(\.rowID), matches.map(\.rowID))
    }

    private func message(_ id: Int64, box: Int64, date: Double, key: String? = nil) -> MailSummary {
        MailSummary(rowID: id, mailbox: box, subject: "", senderName: "", senderAddress: "", snippet: "", date: Date(timeIntervalSince1970: date),
                    read: false, flagged: false, conversation: id, messageKey: key)
    }

    @MainActor private func makeModel() -> MailModel {
        let fixtureRoot = root
        return MailModel(quill: { _ in throw CancellationError() }, quillAllowed: { false }, statusProvider: { .ready(root: fixtureRoot) })
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for the mail model")
    }
}
