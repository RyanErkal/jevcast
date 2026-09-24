import XCTest
@testable import LauncherCore

final class DictationTests: XCTestCase {
    func testHoldStartsAndReleaseFinishes() {
        var hold = DictationHold()
        XCTAssertEqual(hold.handle(.rightCommand(down: true, at: 10)), .start)
        XCTAssertEqual(hold.handle(.rightCommand(down: false, at: 11.5)), .finish(duration: 1.5))
        XCTAssertFalse(hold.isHolding)
    }

    func testShortTapCancels() {
        var hold = DictationHold()
        XCTAssertEqual(hold.handle(.rightCommand(down: true, at: 10)), .start)
        XCTAssertEqual(hold.handle(.rightCommand(down: false, at: 10.15)), .cancel)
        XCTAssertEqual(hold.handle(.rightCommand(down: true, at: 11)), .start, "The next hold works.")
    }

    func testChordCancelsUntilRelease() {
        var hold = DictationHold()
        XCTAssertEqual(hold.handle(.rightCommand(down: true, at: 10)), .start)
        XCTAssertEqual(hold.handle(.otherKey), .cancel, "⌘C is a shortcut, not dictation.")
        XCTAssertNil(hold.handle(.otherKey))
        XCTAssertNil(hold.handle(.rightCommand(down: false, at: 12)), "Release after a chord does nothing.")
        XCTAssertEqual(hold.handle(.rightCommand(down: true, at: 13)), .start)
    }

    func testOtherKeysWhileIdleDoNothing() {
        var hold = DictationHold()
        XCTAssertNil(hold.handle(.otherKey))
        XCTAssertNil(hold.handle(.rightCommand(down: false, at: 1)))
    }

    func testLocalCleanup() {
        XCTAssertEqual(DictationText.clean("  um, so I think   uh we should erm go  "), "So I think we should go")
        XCTAssertEqual(DictationText.clean("Umm. hello Uh there"), "Hello there")
        XCTAssertEqual(DictationText.clean("the drum and the humble umbrella"), "The drum and the humble umbrella", "Only whole words.")
        XCTAssertEqual(DictationText.clean("hello , world"), "Hello, world")
        XCTAssertEqual(DictationText.clean("um uh"), "")
        XCTAssertEqual(DictationText.clean("éclair time"), "Éclair time")
    }

    private func makeStore() -> (TranscriptStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DictationTests-" + UUID().uuidString)
        return (TranscriptStore(folder: folder), folder)
    }

    func testStoreWritesAndReadsNewestFirst() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Transcript(text: "First", date: Date(timeIntervalSince1970: 1_700_000_000), duration: 1.2, target: "com.apple.Notes", engine: "apple-speech")
        let new = Transcript(text: "Second", date: Date(timeIntervalSince1970: 1_700_000_100), duration: 2, target: nil, engine: "apple-speech+luna")
        try store.append(old, retention: .all)
        try store.append(new, retention: .all)
        XCTAssertEqual(store.all(), [new, old])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".jsonl"))
        let lines = try String(contentsOf: folder.appendingPathComponent(files[0]), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }

    func testRetention() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let recent = Transcript(text: "Recent", date: now.addingTimeInterval(-86_400), duration: 1, target: nil, engine: "apple-speech")
        let stale = Transcript(text: "Stale", date: now.addingTimeInterval(-40 * 86_400), duration: 1, target: nil, engine: "apple-speech")
        try store.append(recent, retention: .days30)
        try store.append(stale, retention: .days30)
        store.prune(.all, now: now)
        XCTAssertEqual(store.all().count, 2)
        store.prune(.days30, now: now)
        XCTAssertEqual(store.all(), [recent])
        try store.append(recent, retention: .none)
        XCTAssertEqual(store.all().count, 1, "Don't keep writes nothing.")
        store.prune(.none, now: now)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testDeleteAll() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.append(Transcript(text: "Hi", date: Date(), duration: 1, target: nil, engine: "apple-speech"), retention: .all)
        store.deleteAll()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testDictationRequestUsesFastModelAndOwnContext() {
        let request = LunaRequest.cleanDictation("um so hello")
        XCTAssertEqual(request.sent, [.dictation])
        XCTAssertFalse(request.reasoning)
        XCTAssertEqual(request.model, LunaRequest.dictationModel)
        XCTAssertTrue(request.system.contains("Do not add content"))
        XCTAssertEqual(SourceQuery.parse("dictation history")?.kind, .dictation)
        XCTAssertEqual(SourceQuery.parse("dictation history meeting")?.filter, "meeting")
    }
}
