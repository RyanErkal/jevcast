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

    @MainActor func testMessageShownOnOpenStaysUnreadUntilYouActOnIt() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        let top = try XCTUnwrap(model.selectedID)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(calls.all.isEmpty, "Opening Mail selects the newest message but marks nothing read.")
        XCTAssertEqual(model.selected?.read, false)
        model.noteUserAction()
        try await wait { calls.contains(true, top) }
        XCTAssertEqual(model.selected?.read, true, "Acting on it, such as scrolling it, counts.")
    }

    /// Mail opens again where you left it, and the message you left stays unread until you act on it.
    @MainActor func testOpeningMailAgainKeepsThePlaceAndTheMessageUnread() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        model.place = .allMail
        try await wait { model.selectedID != nil && !model.isLoading }
        let second = try XCTUnwrap(model.messages.dropFirst().first?.rowID)
        UserDefaults.standard.set(MailReading.MarkRead.threeSeconds.rawValue, forKey: MailReading.markReadKey)
        model.windowIsKey = true
        model.select(second, byUser: true)
        // Mail closes before the read time. A new page opens on the same model, as the launcher does.
        model.windowIsKey = false
        UserDefaults.standard.set(MailReading.MarkRead.onOpen.rawValue, forKey: MailReading.markReadKey)
        let page = MailPage(mail: model)
        model.refreshStatus()
        page.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await wait { !model.isLoading }
        XCTAssertEqual(model.place, .allMail, "Mail opens on the mailbox you left")
        XCTAssertEqual(model.selectedID, second, "Mail opens on the message you left")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(calls.all.isEmpty, "Opening Mail never marks a message read")
        model.moveSelection(1)
        model.moveSelection(-1)
        try await wait { calls.contains(true, second) }
    }

    @MainActor func testTheModelsOwnSelectionsStayUnread() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        XCTAssertTrue(model.refresh())
        try await wait { !model.isLoading }
        model.reload()
        try await wait { !model.isLoading && model.selectedID != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(calls.all.isEmpty, "A reload keeps or picks a message without marking it read")
    }

    @MainActor func testMessageCountsAsReadOnlyOnceTheWindowIsInUse() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        let top = try XCTUnwrap(model.selectedID)
        model.select(top, byUser: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(calls.all.isEmpty, "A window in the background marks nothing read.")
        model.windowIsKey = true
        try await wait { calls.contains(true, top) }
    }

    @MainActor func testReadChangeSurvivesRefreshUntilIndexShowsIt() async throws {
        let calls = Calls()
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        let top = try XCTUnwrap(model.selectedID)
        model.select(top, byUser: true)
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
        model.select(top, byUser: true)
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

    @MainActor func testSearchPickStaysUnreadUntilYouActOnIt() async throws {
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
        XCTAssertFalse(calls.contains(true, match), "The first match of a search is the model's own pick.")
        model.select(match, byUser: true)
        try await wait { calls.contains(true, match) }
    }

    /// A message you ask to open, such as from the launcher's search, opens even when a filter
    /// would hide it, and the request never waits for a later reload.
    @MainActor func testOpeningAMessageClearsAFilterThatHidesIt() async throws {
        try write("UPDATE messages SET read = 1 WHERE ROWID IN (3, 4)")
        let calls = Calls()
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        var filter = MailFilter()
        filter.unreadOnly = true
        model.filter = filter
        try await wait { !model.isLoading && model.activeFilterRows != nil && !model.messages.contains { $0.rowID == 3 } }
        let page = MailPage(mail: model)
        page.show(3)
        try await wait { model.selectedID == 3 && !model.isLoading }
        XCTAssertTrue(model.filter.isEmpty, "The Unread filter would hide it, so it went")
        XCTAssertEqual(model.banner, "Filters cleared to show this message.")
        XCTAssertTrue(model.selectionIsUsers, "You chose it")
        XCTAssertNil(model.pending, "Nothing is left for a later reload")
    }

    @MainActor func testFailedChangeShowsIndexState() async throws {
        let calls = Calls()
        calls.fails = true
        let model = try makeModel(calls)
        model.windowIsKey = true
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        model.select(try XCTUnwrap(model.selectedID), byUser: true)
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
