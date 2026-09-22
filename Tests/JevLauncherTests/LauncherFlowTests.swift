import XCTest
@testable import JevLauncher

final class LauncherFlowTests: XCTestCase {
    @MainActor private func withModel(_ body: (LauncherModel) -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false
        preferences.jevEnabled = false
        preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false))
        model.begin()
        defer { model.end() }
        body(model)
    }
    @MainActor func testSpokenUpdateRanksCurrentActionAndTypingReplacesIt() {
        withModel { model in
            model.updateQuery("left half", typed: false)
            XCTAssertEqual(model.selected?.id, "window:left-half")
            model.updateQuery("right third", typed: true)
            XCTAssertEqual(model.selected?.id, "window:right-third")
            XCTAssertFalse(model.speech.isListening)
        }
    }
    @MainActor func testLateTranscriptCannotChangeClosedSession() {
        withModel { model in
            model.updateQuery("left half", typed: false)
            model.end()
            model.speech.onTranscript?("right half")
            XCTAssertEqual(model.query, "left half")
        }
    }
    @MainActor func testManualSelectionSurvivesBackgroundRebuild() {
        withModel { model in
            model.updateQuery("half", typed: true)
            model.moveSelection(1)
            let selected = model.selectedID
            model.rebuild()
            XCTAssertEqual(model.selectedID, selected)
            model.updateQuery("right third", typed: true)
            XCTAssertEqual(model.selected?.id, "window:right-third")
        }
    }
    @MainActor func testDuplicateTranscriptPreservesSelection() {
        withModel { model in
            model.updateQuery("half", typed: false)
            model.moveSelection(1)
            let selected = model.selectedID
            model.speech.onTranscript?("half")
            XCTAssertEqual(model.selectedID, selected)
        }
    }
    @MainActor func testTypingWinsOverLateSpeech() {
        withModel { model in
            model.updateQuery("left half", typed: false)
            model.updateQuery("right third", typed: true)
            model.speech.onTranscript?("left half again")
            XCTAssertEqual(model.query, "right third")
        }
    }
    @MainActor func testExplicitFileSearchCannotExecuteOldWindowOrWebResult() {
        withModel { model in
            model.updateQuery("left half", typed: true)
            XCTAssertNotNil(model.selected)
            model.updateQuery("kind:pdf in:downloads", typed: true)
            XCTAssertTrue(model.isFileSearch)
            XCTAssertNil(model.selected)
            XCTAssertTrue(model.results.isEmpty)
        }
    }
    @MainActor func testInvalidFileFilterStaysInFileMode() {
        withModel { model in
            model.updateQuery("kind:unknown invoices", typed: true)
            XCTAssertTrue(model.isFileSearch)
            XCTAssertFalse(model.results.contains { $0.id == "web" })
            XCTAssertFalse(model.fileStatus.isEmpty)
        }
    }
    @MainActor func testOldFilesRemainVisibleButCannotExecuteWhileSearchUpdates() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false
        let files = HeldFileSearch()
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), files: files)
        model.begin()
        defer { model.end() }
        model.updateQuery("find file alpha", typed: true)
        let firstSearch = expectation(description: "first file request")
        files.onSearch = { firstSearch.fulfill() }
        await fulfillment(of: [firstSearch], timeout: 2)
        let oldCompletion = try XCTUnwrap(files.completion)
        oldCompletion([FileEntry(path: "/test/alpha.txt", name: "alpha.txt")])
        XCTAssertEqual(model.selected?.title, "alpha.txt")
        model.updateQuery("find file beta", typed: true)
        XCTAssertEqual(model.results.first?.title, "alpha.txt")
        XCTAssertFalse(model.results.first?.isCurrent ?? true)
        XCTAssertNil(model.selected)
        model.select("file:/test/alpha.txt")
        XCTAssertNil(model.selected)
        // An old callback cannot publish under the new text.
        oldCompletion([FileEntry(path: "/test/wrong.txt", name: "wrong.txt")])
        XCTAssertFalse(model.results.contains { $0.title == "wrong.txt" })
        let secondSearch = expectation(description: "second file request")
        files.onSearch = { secondSearch.fulfill() }
        await fulfillment(of: [secondSearch], timeout: 2)
        files.completion?([FileEntry(path: "/test/beta.txt", name: "beta.txt")])
        XCTAssertEqual(model.selected?.title, "beta.txt")
        XCTAssertTrue(model.results.allSatisfy(\.isCurrent))
    }
    @MainActor func testCalculatorAndURLDoNotNeedAI() {
        withModel { model in
            model.updateQuery("12 * (8 + 2)", typed: true)
            XCTAssertEqual(model.selected?.id, "calculator")
            XCTAssertEqual(model.selected?.title, "120")
            model.updateQuery("example.com", typed: true)
            XCTAssertEqual(model.selected?.id, "url")
            model.updateQuery("not a url", typed: true)
            XCTAssertFalse(model.results.contains { $0.id == "url" })
        }
    }
}

@MainActor private final class HeldFileSearch: FileSearching {
    var onStatus: ((String) -> Void)?
    var onSearch: (() -> Void)?
    var completion: (([FileEntry]) -> Void)?
    func stop() {}
    func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void) {
        self.completion = completion
        onSearch?()
    }
}
