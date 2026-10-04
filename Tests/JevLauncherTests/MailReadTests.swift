import XCTest
import SQLite3
import LauncherCore
@testable import JevLauncher

/// When a message on screen counts as read, and how the list keeps that state while Mail's index catches up.
/// A fake read action stands in for Apple Mail.
final class MailReadTests: XCTestCase {
    private var root = ""

    /// Read changes the model asked Mail for, in order.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(read: Bool, rowID: Int64)] = []
        var fails = false
        func add(_ read: Bool, _ rowID: Int64) { lock.withLock { items.append((read, rowID)) } }
        var all: [(read: Bool, rowID: Int64)] { lock.withLock { items } }
        func contains(_ read: Bool, _ rowID: Int64) -> Bool { all.contains { $0.read == read && $0.rowID == rowID } }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-read-" + UUID().uuidString).path
        try MailFixture.build(root: root, layout: .init(gmailInbox: 20, allMailOnly: 0, sent: 0, trash: 0, exchangeInbox: 0, projects: 0, perFolder: 0))
        try write("UPDATE messages SET read = 0")
        UserDefaults.standard.set(MailReading.MarkRead.onOpen.rawValue, forKey: MailReading.markReadKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: MailReading.markReadKey)
        try FileManager.default.removeItem(atPath: root)
    }

    @MainActor func testMessageShownOnOpenCountsAsRead() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        let top = try XCTUnwrap(model.selectedID)
        try await wait { calls.contains(true, top) }
        XCTAssertEqual(model.selected?.read, true)
    }

    @MainActor func testMessageCountsAsReadOnlyOnceTheWindowIsInUse() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(calls.all.isEmpty, "A window in the background marks nothing read.")
        model.windowIsKey = true
        let top = try XCTUnwrap(model.selectedID)
        try await wait { calls.contains(true, top) }
    }

    @MainActor func testReadChangeSurvivesRefreshUntilIndexShowsIt() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        let top = try XCTUnwrap(model.selectedID)
        try await wait { calls.contains(true, top) }

        // Mail has not written the change to its index yet.
        XCTAssertTrue(model.refresh())
        try await wait { !model.isLoading }
        XCTAssertEqual(model.selected?.read, true, "A refresh before the index catches up must not mark the row unread again.")

        // The index shows the change, then another device marks the message unread.
        try write("UPDATE messages SET read = 1 WHERE ROWID = \(top)")
        XCTAssertTrue(model.refresh())
        try await wait { !model.isLoading }
        try write("UPDATE messages SET read = 0 WHERE ROWID = \(top)")
        XCTAssertTrue(model.refresh())
        try await wait { !model.isLoading }
        XCTAssertEqual(model.selected?.read, false, "Once the index confirms a change, it decides again.")
    }

    @MainActor func testMarkedUnreadStaysUnreadUntilYouMoveAway() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        let top = try XCTUnwrap(model.selectedID)
        try await wait { calls.contains(true, top) }

        model.toggleRead()
        try await wait { calls.contains(false, top) }
        model.windowIsKey = false
        model.windowIsKey = true
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls.all.filter { $0.rowID == top }.map(\.read), [true, false], "Coming back to the window keeps it unread.")
        XCTAssertEqual(model.selected?.read, false)

        model.moveSelection(1)
        model.moveSelection(-1)
        try await wait { calls.all.filter { $0.rowID == top }.map(\.read) == [true, false, true] }
    }

    @MainActor func testSearchPickCountsAsReadOnceTheSearchSettles() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        let top = try XCTUnwrap(model.selectedID)
        model.search = "body5."
        try await wait { model.messages.count == 1 && !model.isLoading && model.selectedID != top }
        let match = try XCTUnwrap(model.selectedID)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(calls.contains(true, match), "The first match of a search waits while the search may still change.")
        try await wait { calls.contains(true, match) }
    }

    @MainActor func testFailedChangeShowsIndexState() async throws {
        let calls = Calls()
        calls.fails = true
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        try await wait { model.banner != nil }
        try await wait { !model.isLoading }
        XCTAssertEqual(model.selected?.read, false, "A change Mail refused must not stay on screen.")
    }

    // MARK: Helpers

    @MainActor private func makeModel(_ calls: Calls) throws -> MailModel {
        try skipLiveMailModelOnCI()
        let fixtureRoot = root
        return MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, statusProvider: { .ready(root: fixtureRoot) },
                         setRead: { read, message, _, _ in
                             calls.add(read, message.rowID)
                             if calls.fails { throw LauncherError("Mail did not answer.") }
                         })
    }

    private func write(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(MailStore.indexPath(root), &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteReader.Failure(text: String(cString: sqlite3_errmsg(db)))
        }
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for the mail model")
    }
}
