import XCTest
import LauncherCore
import SQLite3
@testable import JevLauncher

@MainActor final class FakeSource: ThingSource {
    let section = "Fake Things"
    var loads = 0
    var ran: [String] = []
    var problem: SourceProblem?
    func load(_ filter: String) async throws -> [LauncherResult] {
        loads += 1
        if let problem { throw problem }
        let stay = Verb(title: "Mark", after: .stay) { [weak self] in self?.ran.append("mark"); return "Marked." }
        let open = Verb(title: "Open Thing") { [weak self] in self?.ran.append("open"); return nil }
        return [LauncherResult(id: "fake:1", title: "Thing " + filter, detail: "detail", symbol: "star",
                               action: .thing(Thing(verbs: [open, stay])), score: 2000)]
    }
}

final class SourceFlowTests: XCTestCase {
    @MainActor private func withModel(_ body: (LauncherModel, FakeSource) async throws -> Void) async rethrows {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false),
                                  keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        let source = FakeSource()
        model.sources[.scheduled] = source
        model.begin()
        defer { model.end() }
        try await body(model, source)
    }

    @MainActor func testSourceRowsLoadAndReturnRunsPrimaryVerb() async throws {
        try await withModel { model, source in
            var closed: Bool?
            model.onClose = { closed = $0 }
            model.updateQuery("scheduled tasks nightly", typed: true)
            try await until { model.selected?.id == "fake:1" }
            XCTAssertEqual(model.selected?.title, "Thing nightly")
            XCTAssertEqual(model.rows.first?.id, "section:Fake Things")
            XCTAssertEqual(model.primaryActionTitle, "Open Thing")
            model.execute()
            XCTAssertEqual(closed, false, "An opening verb closes and keeps focus where it went.")
            try await until { source.ran == ["open"] }
        }
    }

    @MainActor func testStayVerbKeepsLauncherOpenAndReloads() async throws {
        try await withModel { model, source in
            var closed: Bool?
            model.onClose = { closed = $0 }
            model.updateQuery("cron", typed: true)
            try await until { model.selected?.id == "fake:1" }
            guard case .thing(let thing) = model.selected!.action else { return XCTFail("Expected a thing row") }
            let loadsBefore = source.loads
            model.run(thing.verbs[1], on: model.selected!)
            try await until { model.notice?.text == "Marked." && source.loads > loadsBefore }
            XCTAssertNil(closed)
            XCTAssertEqual(source.ran, ["mark"])
        }
    }

    @MainActor func testSourceProblemShowsGrantButton() async throws {
        try await withModel { model, source in
            source.problem = SourceProblem(text: "Allow access.", access: .fullDiskAccess)
            model.updateQuery("launchd", typed: true)
            try await until { model.notice?.text == "Allow access." }
            XCTAssertEqual(model.notice?.action, .grant(.fullDiskAccess))
        }
    }
}

@MainActor func until(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return XCTFail("Condition not met in time") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

final class BrowserHelperTests: XCTestCase {
    func testLikePatternEscapesWildcards() {
        XCTAssertEqual(SQLiteReader.likePattern("50%_off\\x"), "%50\\%\\_off\\\\x%")
    }

    @MainActor func testDuplicateTabsKeepTheFirst() {
        let a = BrowserTab(browser: "b", windowID: "1", key: "1", title: "A", url: "https://a", active: true)
        let b = BrowserTab(browser: "b", windowID: "1", key: "2", title: "A again", url: "https://a", active: false)
        let c = BrowserTab(browser: "b", windowID: "2", key: "3", title: "C", url: "https://c", active: true)
        XCTAssertEqual(TabsSource.duplicates([a, b, c]), [b])
    }

    func testContextSummary() {
        XCTAssertEqual(FrontContext.files(["/a/one.txt", "/a/two.txt", "/a/three.txt", "/a/four.txt"]).summary, "one.txt, two.txt, three.txt and 1 more")
        XCTAssertEqual(FrontContext.page(title: "", url: "https://x", browser: "b").summary, "https://x")
        XCTAssertEqual(FrontContext.text("hello\nworld", app: "Notes").summary, "“hello”")
    }

    func testSQLiteReaderBindsValues() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE t (a TEXT, b INTEGER); INSERT INTO t VALUES ('x''y', 1), ('z', 2);", nil, nil, nil)
        sqlite3_close(db)
        let reader = try SQLiteReader(path: path)
        XCTAssertEqual(try reader.rows("SELECT b FROM t WHERE a = ?1", [.text("x'y")]).first?.first?.int, 1)
        XCTAssertEqual(reader.columns("t"), ["a", "b"])
        XCTAssertEqual(reader.columns("t; DROP TABLE t"), [])
    }
}
