import XCTest
@testable import JevLauncher
import LauncherCore

/// "/" function search, "$" library search, and Tab completion.
@MainActor final class FunctionFlowTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() { suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }; super.tearDown() }

    private func makeModel(jev: CountingJev = CountingJev(), files: CountingFiles? = nil) -> LauncherModel {
        let suite = "FunctionFlowTests." + UUID().uuidString
        suites.append(suite)
        let preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.voiceEnabled = false; preferences.jevEnabled = true; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), files: files ?? CountingFiles(),
                                  jev: jev, keys: JevKeyCache(key: "test-key"), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        model.begin()
        return model
    }

    func testPrefixQueryNeverAsksJevOrSearchesFiles() async throws {
        let jev = CountingJev(), files = CountingFiles()
        let model = makeModel(jev: jev, files: files); defer { model.end() }
        model.updateQuery("/calendar please", typed: true)
        model.updateQuery("$deploy the thing", typed: true)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(jev.calls, 0)
        XCTAssertEqual(files.searches, 0)
    }

    func testTodoFindsRemindersAndTasksOpensLunaTasksView() {
        let model = makeModel(); defer { model.end() }
        var opened: [String] = []
        model.openView = { opened.append($0) }
        model.updateQuery("/todo", typed: true)
        XCTAssertEqual(model.selected?.id, "source:reminders")
        if case .route(let text) = model.selected?.action { XCTAssertTrue(text.hasPrefix("reminders")) } else { XCTFail("Reminders routes to its list") }
        model.updateQuery("/luna tasks", typed: true)
        XCTAssertEqual(model.selected?.id, "view:tasks")
        model.execute()
        XCTAssertEqual(opened, ["tasks"])
    }

    func testPrefixPickIsNotLearnedAndViewPathFreezes() {
        let model = makeModel(); defer { model.end() }
        var opened: [String] = []
        model.openSettingsTab = { opened.append($0) }
        model.openView = { opened.append($0) }
        model.updateQuery("/ai settings", typed: true)
        model.execute()
        XCTAssertNil(model.preferences.learned.lookup("/ai settings"))
        model.begin()
        model.updateQuery("/calendar", typed: true)
        let before = model.revision
        model.execute()
        XCTAssertNotEqual(model.revision, before, "Opening a view drops late work.")
        XCTAssertEqual(opened.last, "calendar")
    }

    func testEveryEntryHasARowAndKnownTarget() {
        let model = makeModel(); defer { model.end() }
        model.updateQuery("/", typed: true)
        let ids = Set(model.results.map(\.id))
        for entry in FunctionCatalog.builtIn {
            XCTAssertTrue(ids.contains(entry.id), entry.id + " has no row")
            if entry.id.hasPrefix("settings:") { XCTAssertNotNil(SettingsWindow.Tab(rawValue: String(entry.id.dropFirst(9))), entry.id) }
            if entry.id.hasPrefix("view:") { XCTAssertNotNil(ViewID(rawValue: String(entry.id.dropFirst(5))), entry.id) }
        }
        XCTAssertEqual(Set(FunctionCatalog.views.map(\.id)), Set(ViewID.allCases.map { "view:" + $0.rawValue }))
    }

    func testTabCompletesAndKeepsSelection() {
        let model = makeModel(); defer { model.end() }
        model.updateQuery("/", typed: true)
        model.select("settings:ai")
        XCTAssertTrue(model.completePrefix())
        XCTAssertEqual(model.query, "/AI Settings")
        XCTAssertEqual(model.selected?.id, "settings:ai")
        model.updateQuery("hello", typed: true)
        XCTAssertFalse(model.completePrefix())
        // "2FA codes" after "$" would read as money, so Tab keeps the query.
        model.preferences.snippets = [Snippet(name: "2FA codes", text: "x")]
        model.updateQuery("$codes", typed: true)
        XCTAssertTrue(model.completePrefix())
        XCTAssertEqual(model.query, "$codes")
    }

    func testDollarAmountsAndEmptyLibrary() {
        XCTAssertNil(PrefixQuery.parse("$120"))
        XCTAssertNil(PrefixQuery.parse("$120 to eur"))
        let model = makeModel(); defer { model.end() }
        model.updateQuery("$120", typed: true)
        XCTAssertFalse(model.results.contains { $0.section == .named("Library") })
        model.updateQuery("$", typed: true)
        XCTAssertEqual(model.results.map(\.id), ["settings:library"], "An empty library points to Settings.")
        model.preferences.snippets = [Snippet(name: "Sig", text: "Hi")]
        model.updateQuery("$AAPL", typed: true)
        XCTAssertEqual(model.results.map(\.id), ["web"])
        if case .url(let url) = model.results.first?.action { XCTAssertTrue(url.absoluteString.hasSuffix("q=AAPL")) }
    }

    func testTopLevelFolderStaysAPath() {
        XCTAssertNil(LauncherModel.prefix(for: "/tmp", root: ["tmp", "Applications"]))
        XCTAssertNil(LauncherModel.prefix(for: "/Applications", root: ["tmp", "Applications"]))
        XCTAssertNil(LauncherModel.prefix(for: "/applications", root: ["Applications"]), "No function matches, so it is a path.")
        XCTAssertEqual(LauncherModel.prefix(for: "/library", root: ["Library"]), .functions("library"), "Library Settings matches.")
        XCTAssertEqual(LauncherModel.prefix(for: "/cal", root: ["tmp"]), .functions("cal"))
        let model = makeModel(); defer { model.end() }
        model.updateQuery("/tmp", typed: true)
        XCTAssertTrue(model.isFileSearch)
    }
}

final class CountingJev: JevChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func choose(query: String, candidates: [JevCandidate], apiKey: String) async throws -> String? {
        lock.withLock { count += 1 }
        return nil
    }
}

@MainActor final class CountingFiles: FileSearching {
    var onStatus: ((String) -> Void)?
    var searches = 0
    func stop() {}
    func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void) { searches += 1; completion([]) }
}
