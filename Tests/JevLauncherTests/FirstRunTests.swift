import XCTest
@testable import JevLauncher

final class FirstRunTests: XCTestCase {
    func testInstallLocationWarnings() {
        let home = "/Users/test"
        func warning(_ path: String) -> String? { InstallLocation.warning(for: URL(fileURLWithPath: path), home: home) }
        XCTAssertNil(warning("/Applications/Jev Launcher.app"))
        XCTAssertNil(warning("/Users/test/Applications/Jev Launcher.app"))
        XCTAssertNotNil(warning("/Users/test/Downloads/Jev Launcher.app"))
        XCTAssertNotNil(warning("/Users/tester/Applications/Jev Launcher.app"), "Another user's Applications folder is not this one.")
        XCTAssertTrue(warning("/Volumes/Jev Launcher/Jev Launcher.app")?.contains("temporary") == true)
        XCTAssertTrue(warning("/private/var/folders/xy/T/AppTranslocation/1A2B/d/Jev Launcher.app")?.contains("temporary") == true)
    }

    @MainActor func testNewInstallStartsWithoutMicrophoneAndShowsWelcomeUntilShown() {
        withDefaults { defaults in
            let first = Preferences(defaults: defaults)
            XCTAssertFalse(first.voiceEnabled, "A new install does not listen until the user turns voice on.")
            XCTAssertFalse(first.welcomeShown)
            XCTAssertTrue(first.checksForUpdates)
            let second = Preferences(defaults: defaults)
            XCTAssertFalse(second.voiceEnabled, "The second launch keeps the first launch's defaults.")
            XCTAssertFalse(second.welcomeShown, "Only showing the window marks it shown.")
        }
    }

    @MainActor func testEarlierInstallKeepsListeningAndSkipsWelcome() {
        withDefaults { defaults in
            defaults.set(["app:/Applications/Safari.app"], forKey: "recentIDs")
            let preferences = Preferences(defaults: defaults)
            XCTAssertTrue(preferences.voiceEnabled, "Earlier versions listened by default.")
            XCTAssertTrue(preferences.welcomeShown)
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
