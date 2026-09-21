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
