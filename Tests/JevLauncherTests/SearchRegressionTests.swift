import AppKit
import LauncherCore
import XCTest
@testable import JevLauncher

@MainActor
final class SearchRegressionTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func makeModel(jev: JevChoosing = RegressionJev()) async throws -> LauncherModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        for (name, id) in [("System Settings", "com.apple.systempreferences"), ("Safari", "test.safari"),
                           ("T3 Code (Nightly)", "test.nightly"), ("t3codev2", "test.v2")] {
            let contents = root.appendingPathComponent(name + ".app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleName": name, "CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let suite = "SearchRegressionTests." + UUID().uuidString
        suites.append(suite)
        let preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let catalogue = AppCatalogue(loadCache: false, roots: [root.path], persistsCache: false)
        catalogue.refresh(extra: [])
        let deadline = Date().addingTimeInterval(2)
        while catalogue.scanning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(catalogue.scanning)
        let model = LauncherModel(preferences: preferences, catalogue: catalogue, files: RegressionFiles(),
                                  jev: jev, keys: JevKeyCache(key: "fixture-key"),
                                  clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        model.visible = true
        return model
    }

    func testBareSettingsSelectsOnlyTheApplication() async throws {
        let model = try await makeModel(); defer { model.end() }
        for query in ["settings", "open settings", "system settings"] {
            model.updateQuery(query, typed: true)
            XCTAssertEqual(model.selected?.title, "System Settings", query)
            XCTAssertFalse(model.results.contains { row in
                if case .app(let app) = row.action { return app.launchURL != nil }
                return false
            }, query)
        }
    }

    func testQualifiedSettingsMatchOnlyTheRequestedPane() async throws {
        let model = try await makeModel(); defer { model.end() }
        let settings = try XCTUnwrap(model.catalogue.entries.first { $0.name == "System Settings" })
        model.preferences.favourites = [settings.id]
        for _ in 0..<100 { model.preferences.record(settings.id, query: "focus settings") }
        for (query, title) in [("bluetooth settings", "Bluetooth Settings"), ("wifi settings", "Wi-Fi Settings"), ("focus settings", "Focus Settings")] {
            model.updateQuery(query, typed: true)
            let panes = model.results.compactMap { row -> String? in
                if case .app(let app) = row.action, app.launchURL != nil { return row.title }
                return nil
            }
            XCTAssertEqual(panes, [title], query)
            XCTAssertEqual(model.selected?.title, title)
        }
    }

    func testCompactT3NameKeepsNightlyAboveTheOtherApp() async throws {
        let model = try await makeModel(); defer { model.end() }
        for query in ["t3code", "t3code nightly", "t3 code nightly"] {
            model.updateQuery(query, typed: true)
            XCTAssertEqual(model.selected?.title, "T3 Code (Nightly)", query)
        }
    }

    func testFavouriteAndUseCannotBeatAnExactName() async throws {
        let model = try await makeModel(); defer { model.end() }
        let safari = try XCTUnwrap(model.catalogue.entries.first { $0.name == "Safari" })
        model.preferences.customCommands = [CustomCommand(name: "SAF", command: "true")]
        model.preferences.favourites = [safari.id]
        for _ in 0..<100 { model.preferences.record(safari.id, query: "saf") }
        model.updateQuery("saf", typed: true)
        XCTAssertEqual(model.selected?.title, "SAF")
    }

    func testSavedAndCachedAnswersCannotRestoreHiddenAppsOrUnrequestedPanes() async throws {
        let model = try await makeModel(); defer { model.end() }
        let safari = try XCTUnwrap(model.catalogue.entries.first { $0.name == "Safari" })
        let pane = try XCTUnwrap(model.catalogue.entries.first { $0.name == "Bluetooth Settings" })
        model.preferences.hiddenApps = [safari.id]
        for (query, id, cached) in [("my reading tool", safari.id, false), ("my browser tool", safari.id, true),
                                   ("radio controls", pane.id, false), ("wireless controls", pane.id, true)] {
            if cached { model.replyCache[LearnedIntents.normalize(query)] = (id, Date()); model.preferences.jevEnabled = true }
            else { model.preferences.learn(query, id: id) }
            model.updateQuery(query, typed: true)
            try await Task.sleep(nanoseconds: 180_000_000)
            XCTAssertFalse(model.results.contains { $0.id == id }, query)
        }
    }

    func testDelayedSavedAnswerCannotReplaceANewExactMatch() async throws {
        let model = try await makeModel(); defer { model.end() }
        let safari = try XCTUnwrap(model.catalogue.entries.first { $0.name == "Safari" })
        model.preferences.learn("launch reader", id: safari.id)
        model.updateQuery("launch reader", typed: true)
        model.preferences.customCommands = [CustomCommand(name: "Launch Reader", command: "true")]
        model.rebuild()
        let exactID = model.selectedID
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(model.selectedID, exactID)
        XCTAssertEqual(model.selected?.title, "Launch Reader")
    }

    func testManualSelectionStopsALateJevRoute() async throws {
        let jev = RegressionJev(title: "Find files", delay: 200_000_000)
        let model = try await makeModel(jev: jev); defer { model.end() }
        model.preferences.jevEnabled = true; model.preferences.jevLayered = false
        model.updateQuery("plum wobble", typed: true)
        try await Task.sleep(nanoseconds: 350_000_000)
        model.moveSelection(1)
        let selected = model.selectedID
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.query, "plum wobble")
        XCTAssertEqual(model.selectedID, selected)
    }

    func testHeldReturnCannotConfirmAnAction() async throws {
        let model = try await makeModel(); defer { model.end() }
        var runs = 0
        model.updateQuery("fixture", typed: true)
        let verb = Verb(title: "Run inert fixture", confirm: true, after: .keepOpen, run: { runs += 1; return nil })
        model.sourceRows = [LauncherResult(id: "fixture", title: "Fixture", detail: "", symbol: "gearshape",
                                          action: .thing(Thing(verbs: [verb])), score: 2000)]
        model.rebuild()
        func key(repeatKey: Bool) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: 36)!
        }
        model.handleSearchReturn(key(repeatKey: false))
        model.handleSearchReturn(key(repeatKey: true))
        await Task.yield()
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(model.pendingConfirmID, "fixture")
        model.handleSearchReturn(key(repeatKey: false))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(runs, 1)
    }

    func testCompositionCancelsLatePicksAndCommitsOnlyFinishedText() async throws {
        let jev = RegressionJev(title: "Find files", delay: 200_000_000)
        let model = try await makeModel(jev: jev); defer { model.end() }
        model.preferences.jevEnabled = true; model.preferences.jevLayered = false
        model.updateQuery("plum wobble", typed: true)
        try await Task.sleep(nanoseconds: 350_000_000)
        model.updateSearchField("unfinished", composing: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.query, "plum wobble")
        model.updateSearchField("settings", composing: false)
        XCTAssertFalse(model.isComposingSearch)
        XCTAssertEqual(model.query, "settings")
        XCTAssertEqual(model.selected?.title, "System Settings")
    }

    func testFailedAppLaunchDoesNotRecordUseOrLearnTheRequest() async throws {
        let model = try await makeModel(); defer { model.end() }
        let launcher = HeldApplicationLauncher()
        model.applicationLauncher = launcher
        model.updateQuery("nightly", typed: true)
        let app = try XCTUnwrap(model.catalogue.entries.first { $0.name == "T3 Code (Nightly)" })
        model.aiStatus = "No clear AI match"
        model.execute(); model.execute()
        XCTAssertEqual(launcher.calls, 1)
        XCTAssertFalse(model.preferences.recentIDs.contains(app.id))
        XCTAssertNil(model.preferences.learned.lookup("nightly"))
        launcher.finish(.failure(LauncherError("Fixture launch failure")))
        XCTAssertFalse(model.preferences.recentIDs.contains(app.id))
        XCTAssertNil(model.preferences.learned.lookup("nightly"))
        XCTAssertEqual(model.message, "Fixture launch failure")
        XCTAssertNil(model.launchingAppID)
    }

    func testSuccessfulAppLaunchRemembersTheExecutedQueryOnlyAfterCompletion() async throws {
        let model = try await makeModel(); defer { model.end() }
        let launcher = HeldApplicationLauncher()
        model.applicationLauncher = launcher
        model.updateQuery("nightly", typed: true)
        model.aiStatus = "No clear AI match"
        let id = try XCTUnwrap(model.selectedID)
        var closes = 0
        model.onClose = { _ in closes += 1 }
        model.execute()
        XCTAssertEqual(model.preferences.frecency.score(id), 0)
        model.updateQuery("settings", typed: true)
        launcher.finish(.success(()))
        XCTAssertEqual(model.preferences.learned.lookup("nightly"), id)
        XCTAssertNil(model.preferences.learned.lookup("settings"))
        XCTAssertEqual(model.preferences.frecency.learned(for: "nightly")?.id, id)
        XCTAssertEqual(closes, 0, "A late app launch must not close a new query")
    }

    func testAppLaunchDoesNotReportIntoANewerSession() async throws {
        let model = try await makeModel(); defer { model.end() }
        let launcher = HeldApplicationLauncher()
        model.applicationLauncher = launcher
        model.updateQuery("nightly", typed: true)
        model.execute()
        model.end(); model.begin()
        var failures = 0
        model.onFailure = { _ in failures += 1 }
        launcher.finish(.failure(LauncherError("Old session failure")))
        XCTAssertEqual(failures, 0)
        XCTAssertNil(model.message)
        XCTAssertNil(model.launchingAppID)
    }
}

@MainActor private final class HeldApplicationLauncher: ApplicationLaunching {
    var calls = 0
    var completion: (@MainActor (Result<Void, Error>) -> Void)?
    func open(_ app: AppEntry, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        calls += 1; self.completion = completion
    }
    func finish(_ result: Result<Void, Error>) { completion?(result); completion = nil }
}

private final class RegressionJev: JevChoosing, @unchecked Sendable {
    let title: String?
    let delay: UInt64
    init(title: String? = nil, delay: UInt64 = 0) { self.title = title; self.delay = delay }
    func choose(query: String, candidates: [JevCandidate], apiKey: String) async throws -> String? {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return candidates.first { $0.title == title }?.id
    }
}

@MainActor private final class RegressionFiles: FileSearching {
    var onStatus: ((String) -> Void)?
    func stop() {}
    func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void) { completion([]) }
}
