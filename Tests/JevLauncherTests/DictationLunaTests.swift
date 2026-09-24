import XCTest
import LauncherCore
@testable import JevLauncher

/// Luna sees a dictation transcript only when both Luna and "Dictation transcripts" are on.
final class DictationLunaTests: XCTestCase {
    @MainActor private func makeModel(luna: LunaWriting) -> (LauncherModel, Preferences, () -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), keys: JevKeyCache(key: nil),
                                  clipboard: ClipboardHistory(pasteboard: FakePasteboard()), luna: luna, lunaKeys: JevKeyCache(key: "sk-or-test"),
                                  lunaLog: LunaActivityLog(defaults: defaults))
        return (model, preferences, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor func testSwitchOffSendsNothing() async {
        let luna = FakeLuna(reply: "Luna text.")
        let (model, preferences, cleanup) = makeModel(luna: luna)
        defer { cleanup() }
        XCTAssertFalse(preferences.lunaSendsDictation, "Off by default.")
        preferences.lunaEnabled = true
        let result = await model.cleanDictation("um hello there")
        XCTAssertEqual(result, .init(text: "Hello there", usedLuna: false))
        XCTAssertTrue(luna.requests.isEmpty)
        do {
            _ = try await model.sendLuna(.cleanDictation("hello"))
            XCTFail("The checked path must refuse a dictation request while the switch is off.")
        } catch {}
        XCTAssertTrue(luna.requests.isEmpty)
    }

    @MainActor func testSwitchOnSendsAndLogsWithoutText() async throws {
        let luna = FakeLuna(reply: "Hello there.")
        let (model, preferences, cleanup) = makeModel(luna: luna)
        defer { cleanup() }
        preferences.lunaEnabled = true
        preferences.lunaSendsDictation = true
        let result = await model.cleanDictation("um hello there")
        XCTAssertEqual(result, .init(text: "Hello there.", usedLuna: true))
        XCTAssertEqual(luna.requests.first?.sent, [.dictation])
        let entry = try XCTUnwrap(model.lunaLog.entries.first)
        XCTAssertEqual(entry.action, "Dictation clean-up")
        XCTAssertEqual(entry.sent, [.dictation])
        preferences.lunaSendsDictation = false
        _ = await model.cleanDictation("again")
        XCTAssertEqual(luna.requests.count, 1, "Each request checks the switch.")
    }

    @MainActor func testSlowLunaFallsBackToLocalText() async {
        let (model, preferences, cleanup) = makeModel(luna: SlowLuna())
        defer { cleanup() }
        preferences.lunaEnabled = true
        preferences.lunaSendsDictation = true
        let started = Date()
        let result = await model.cleanDictation("uh hello")
        XCTAssertEqual(result, .init(text: "Hello", usedLuna: false))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

private final class SlowLuna: LunaWriting {
    func complete(_ request: LunaRequest, effort: LunaEffort, apiKey: String) async throws -> LunaReply {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return LunaReply(text: "late", inputTokens: 0, outputTokens: 0, cost: nil)
    }
}
