import XCTest
import LauncherCore
@testable import JevLauncher

/// The writing model sees a dictation transcript only when both AI writing and "Dictation transcripts" are on.
final class DictationAIWritingTests: XCTestCase {
    @MainActor private func makeModel(aiWriting: AIWriter) -> (LauncherModel, Preferences, () -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), keys: JevKeyCache(key: nil),
                                  clipboard: ClipboardHistory(pasteboard: FakePasteboard()), aiWriting: aiWriting, aiWritingKeys: JevKeyCache(key: "sk-or-test"),
                                  aiWritingLog: AIWritingActivityLog(defaults: defaults))
        return (model, preferences, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor func testDictationSwitchesAreOffByDefault() {
        let (model, preferences, cleanup) = makeModel(aiWriting: FakeAIWriting())
        defer { cleanup() }
        XCTAssertFalse(preferences.dictationEnabled, "Dictation is off until the user turns it on.")
        XCTAssertFalse(preferences.aiWritingSendsDictation, "AI clean-up is off until the user turns it on.")
        preferences.aiWritingEnabled = true
        XCTAssertFalse(model.allowedAIWritingContext.contains(.dictation), "Turning AI writing on does not allow transcripts.")
        preferences.aiWritingSendsDictation = true
        XCTAssertTrue(model.allowedAIWritingContext.contains(.dictation))
    }

    @MainActor func testSwitchOffSendsNothing() async {
        let aiWriting = FakeAIWriting(reply: "AI text.")
        let (model, preferences, cleanup) = makeModel(aiWriting: aiWriting)
        defer { cleanup() }
        XCTAssertFalse(preferences.aiWritingSendsDictation, "Off by default.")
        preferences.aiWritingEnabled = true
        let result = await model.cleanDictation("hello there")
        XCTAssertEqual(result, .init(text: "Hello there", usedAIWriting: false))
        XCTAssertTrue(aiWriting.requests.isEmpty)
        do {
            _ = try await model.sendAIWriting(.cleanDictation("hello"))
            XCTFail("The checked path must refuse a dictation request while the switch is off.")
        } catch {}
        XCTAssertTrue(aiWriting.requests.isEmpty)
    }

    @MainActor func testSwitchOnSendsAndLogsWithoutText() async throws {
        let aiWriting = FakeAIWriting(reply: "Hello there.")
        let (model, preferences, cleanup) = makeModel(aiWriting: aiWriting)
        defer { cleanup() }
        preferences.aiWritingEnabled = true
        preferences.aiWritingSendsDictation = true
        preferences.aiWritingEffort = .max
        let result = await model.cleanDictation("hello there")
        XCTAssertEqual(result, .init(text: "Hello there.", usedAIWriting: true))
        XCTAssertEqual(aiWriting.requests.first?.sent, [.dictation])
        let entry = try XCTUnwrap(model.aiWritingLog.entries.first)
        XCTAssertEqual(entry.action, "Dictation clean-up")
        XCTAssertEqual(entry.sent, [.dictation])
        XCTAssertEqual(entry.effort, ReasoningEffort.none, "Dictation turns the writing model's reasoning off, whatever Settings say.")
        preferences.aiWritingSendsDictation = false
        _ = await model.cleanDictation("again")
        XCTAssertEqual(aiWriting.requests.count, 1, "Each request checks the switch.")
    }

    @MainActor func testSlowAIWritingFallsBackToLocalText() async {
        let (model, preferences, cleanup) = makeModel(aiWriting: SlowAIWriting())
        defer { cleanup() }
        preferences.aiWritingEnabled = true
        preferences.aiWritingSendsDictation = true
        let started = Date()
        let result = await model.cleanDictation("hello")
        XCTAssertEqual(result, .init(text: "Hello", usedAIWriting: false))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    @MainActor func testReplyThatAddsContentIsDropped() async {
        let aiWriting = FakeAIWriting(reply: "Dear Bob, I hope you are well. The meeting has moved to Friday at ten.")
        let (model, preferences, cleanup) = makeModel(aiWriting: aiWriting)
        defer { cleanup() }
        preferences.aiWritingEnabled = true
        preferences.aiWritingSendsDictation = true
        let result = await model.cleanDictation("write an email to bob")
        XCTAssertEqual(result, .init(text: "Write an email to bob", usedAIWriting: false))
        XCTAssertEqual(aiWriting.requests.count, 1)
    }

    @MainActor func testLongTranscriptKeepsLocalText() async {
        let aiWriting = FakeAIWriting(reply: "Short.")
        let (model, preferences, cleanup) = makeModel(aiWriting: aiWriting)
        defer { cleanup() }
        preferences.aiWritingEnabled = true
        preferences.aiWritingSendsDictation = true
        let long = String(repeating: "word ", count: AIWritingRequest.maxDictation / 4)
        let result = await model.cleanDictation(long)
        XCTAssertFalse(result.usedAIWriting, "The writing model would see only part of it, and the rest would be lost.")
        XCTAssertTrue(aiWriting.requests.isEmpty)
    }
}

private final class SlowAIWriting: AIWriter {
    func complete(_ request: AIWritingRequest, options: AIWritingOptions, apiKey: String) async throws -> AIWritingReply {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return AIWritingReply(text: "late", inputTokens: 0, outputTokens: 0, cost: nil)
    }
}
