import XCTest
@testable import JevLauncher

final class FirstRunTests: XCTestCase {
    func testInstallLocationWarnings() {
        let home = "/Users/test"
        func warning(_ path: String) -> String? { InstallLocation.warning(for: URL(fileURLWithPath: path), home: home) }
        XCTAssertNil(warning("/Applications/Jevcast.app"))
        XCTAssertNil(warning("/Users/test/Applications/Jevcast.app"))
        XCTAssertNotNil(warning("/Users/test/Downloads/Jevcast.app"))
        XCTAssertNotNil(warning("/Users/tester/Applications/Jevcast.app"), "Another user's Applications folder is not this one.")
        XCTAssertTrue(warning("/Volumes/Jevcast/Jevcast.app")?.contains("temporary") == true)
        XCTAssertTrue(warning("/private/var/folders/xy/T/AppTranslocation/1A2B/d/Jevcast.app")?.contains("temporary") == true)
    }

    @MainActor func testNewInstallStartsWithoutMicrophoneAndShowsWelcomeUntilShown() {
        withDefaults { defaults in
            let first = Preferences(defaults: defaults)
            XCTAssertFalse(first.voiceEnabled, "A new install does not listen until the user turns voice on.")
            XCTAssertFalse(first.welcomeShown)
            XCTAssertTrue(first.checksForUpdates)
            XCTAssertEqual(first.hotkey, .optionSpace, "The website tells new users to press Option–Space.")
            let second = Preferences(defaults: defaults)
            XCTAssertFalse(second.voiceEnabled, "The second launch keeps the first launch's defaults.")
            XCTAssertFalse(second.welcomeShown, "Only showing the window marks it shown.")
            XCTAssertEqual(second.hotkey, .optionSpace, "The second launch keeps the first launch's shortcut.")
        }
    }

    @MainActor func testEarlierInstallKeepsListeningAndSkipsWelcome() {
        withDefaults { defaults in
            defaults.set(["app:/Applications/Safari.app"], forKey: "recentIDs")
            let preferences = Preferences(defaults: defaults)
            XCTAssertTrue(preferences.voiceEnabled, "Earlier versions listened by default.")
            XCTAssertTrue(preferences.welcomeShown)
            XCTAssertEqual(preferences.hotkey, .controlShiftSpace, "An earlier install keeps the shortcut it had.")
        }
    }

    @MainActor func testStoredChoicesWin() {
        withDefaults { defaults in
            defaults.set(["app:/Applications/Safari.app"], forKey: "recentIDs")
            defaults.set(false, forKey: "voiceEnabled")
            defaults.set(false, forKey: "checksForUpdates")
            let preferences = Preferences(defaults: defaults)
            XCTAssertFalse(preferences.voiceEnabled)
            XCTAssertFalse(preferences.checksForUpdates)
        }
    }

    @MainActor private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
