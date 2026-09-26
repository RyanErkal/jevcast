import XCTest
import LauncherCore
@testable import JevLauncher

/// Quill sees a dictation transcript only when both Quill and "Dictation transcripts" are on.
final class DictationQuillTests: XCTestCase {
    @MainActor private func makeModel(quill: QuillWriting) -> (LauncherModel, Preferences, () -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), keys: JevKeyCache(key: nil),
                                  clipboard: ClipboardHistory(pasteboard: FakePasteboard()), quill: quill, quillKeys: JevKeyCache(key: "sk-or-test"),
                                  quillLog: QuillActivityLog(defaults: defaults))
        return (model, preferences, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor func testDictationSwitchesAreOffByDefault() {
        let (model, preferences, cleanup) = makeModel(quill: FakeQuill())
        defer { cleanup() }
        XCTAssertFalse(preferences.dictationEnabled, "Dictation is off until the user turns it on.")
        XCTAssertFalse(preferences.quillSendsDictation, "Quill clean-up is off until the user turns it on.")
        preferences.quillEnabled = true
        XCTAssertFalse(model.allowedQuillContext.contains(.dictation), "Turning Quill on does not allow transcripts.")
        preferences.quillSendsDictation = true
        XCTAssertTrue(model.allowedQuillContext.contains(.dictation))
    }

    @MainActor func testSwitchOffSendsNothing() async {
        let quill = FakeQuill(reply: "Quill text.")
        let (model, preferences, cleanup) = makeModel(quill: quill)
        defer { cleanup() }
        XCTAssertFalse(preferences.quillSendsDictation, "Off by default.")
        preferences.quillEnabled = true
        let result = await model.cleanDictation("hello there")
        XCTAssertEqual(result, .init(text: "Hello there", usedQuill: false))
        XCTAssertTrue(quill.requests.isEmpty)
        do {
            _ = try await model.sendQuill(.cleanDictation("hello"))
            XCTFail("The checked path must refuse a dictation request while the switch is off.")
        } catch {}
        XCTAssertTrue(quill.requests.isEmpty)
    }

    @MainActor func testSwitchOnSendsAndLogsWithoutText() async throws {
        let quill = FakeQuill(reply: "Hello there.")
        let (model, preferences, cleanup) = makeModel(quill: quill)
        defer { cleanup() }
        preferences.quillEnabled = true
        preferences.quillSendsDictation = true
        preferences.quillEffort = .max
        let result = await model.cleanDictation("hello there")
        XCTAssertEqual(result, .init(text: "Hello there.", usedQuill: true))
        XCTAssertEqual(quill.requests.first?.sent, [.dictation])
        let entry = try XCTUnwrap(model.quillLog.entries.first)
        XCTAssertEqual(entry.action, "Dictation clean-up")
        XCTAssertEqual(entry.sent, [.dictation])
        XCTAssertEqual(entry.effort, ReasoningEffort.none, "Dictation turns Quill's reasoning off, whatever Settings say.")
        preferences.quillSendsDictation = false
        _ = await model.cleanDictation("again")
        XCTAssertEqual(quill.requests.count, 1, "Each request checks the switch.")
    }

    @MainActor func testSlowQuillFallsBackToLocalText() async {
        let (model, preferences, cleanup) = makeModel(quill: SlowQuill())
        defer { cleanup() }
        preferences.quillEnabled = true
        preferences.quillSendsDictation = true
        let started = Date()
        let result = await model.cleanDictation("hello")
        XCTAssertEqual(result, .init(text: "Hello", usedQuill: false))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    @MainActor func testReplyThatAddsContentIsDropped() async {
        let quill = FakeQuill(reply: "Dear Bob, I hope you are well. The meeting has moved to Friday at ten.")
        let (model, preferences, cleanup) = makeModel(quill: quill)
        defer { cleanup() }
        preferences.quillEnabled = true
        preferences.quillSendsDictation = true
        let result = await model.cleanDictation("write an email to bob")
        XCTAssertEqual(result, .init(text: "Write an email to bob", usedQuill: false))
        XCTAssertEqual(quill.requests.count, 1)
    }

    @MainActor func testLongTranscriptKeepsLocalText() async {
        let quill = FakeQuill(reply: "Short.")
        let (model, preferences, cleanup) = makeModel(quill: quill)
        defer { cleanup() }
        preferences.quillEnabled = true
        preferences.quillSendsDictation = true
        let long = String(repeating: "word ", count: QuillRequest.maxDictation / 4)
        let result = await model.cleanDictation(long)
        XCTAssertFalse(result.usedQuill, "Quill would see only part of it, and the rest would be lost.")
        XCTAssertTrue(quill.requests.isEmpty)
    }
}

private final class SlowQuill: QuillWriting {
    func complete(_ request: QuillRequest, options: QuillOptions, apiKey: String) async throws -> QuillReply {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return QuillReply(text: "late", inputTokens: 0, outputTokens: 0, cost: nil)
    }
}
