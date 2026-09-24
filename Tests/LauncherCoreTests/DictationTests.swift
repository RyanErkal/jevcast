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

    func testPressAfterMissedReleaseStartsAgain() {
        var hold = DictationHold()
        XCTAssertEqual(hold.handle(.rightCommand(down: true, at: 10)), .start)
        XCTAssertEqual(hold.handle(.otherKey), .cancel)
        // The release was never seen, such as during secure input. The next press must still work.
        XCTAssertEqual(hold.handle(.rightCommand(down: true, at: 20)), .start)
        XCTAssertEqual(hold.handle(.rightCommand(down: false, at: 21)), .finish(duration: 1))
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
        XCTAssertEqual(DictationText.clean("eu tenho um  carro", fillers: false), "Eu tenho um carro", "“um” is a word in Portuguese.")
    }

    func testLunaCleanupMayOnlyTidy() {
        XCTAssertTrue(DictationText.isFaithful("Meet at six.", to: "Meet at five, no, six"))
        XCTAssertTrue(DictationText.isFaithful("I don’t know.", to: "I don't know"))
        XCTAssertFalse(DictationText.isFaithful("It is three o'clock.", to: "What time is it"), "An answer is not a clean-up.")
        XCTAssertFalse(DictationText.isFaithful("Dear Bob, I hope you are well. The meeting moved to Friday.", to: "Write an email to Bob"))
        XCTAssertFalse(DictationText.isFaithful("", to: "Hello"))
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
        let file = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(files[0]).path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testDamagedLineIsSkippedAndNextEntryKept() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Transcript(text: "Café", date: Date(timeIntervalSince1970: 1_700_000_000), duration: 1, target: nil, engine: "apple-speech")
        try store.append(first, retention: .all)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        // A crash cut the next line in the middle of "é", so it has no newline and broken UTF-8.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"text":"Caf"#.utf8) + Data([0xC3]))
        try handle.close()
        let next = Transcript(text: "Next", date: Date(timeIntervalSince1970: 1_700_000_050), duration: 1, target: nil, engine: "apple-speech")
        try store.append(next, retention: .all)
        XCTAssertEqual(store.all(), [next, first])
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

    func testDictationRequestTurnsReasoningOffAndUsesOwnContext() {
        let request = LunaRequest.cleanDictation("um so hello")
        XCTAssertEqual(request.sent, [.dictation])
        XCTAssertEqual(request.effort, .off, "Luna with reasoning off, so it is quick.")
        XCTAssertEqual(request.effort?.apiValue, "none")
        XCTAssertNil(LunaRequest.ask("hi").effort, "Other requests follow Settings.")
        XCTAssertTrue(request.system.contains("Do not add content"))
        XCTAssertEqual(SourceQuery.parse("dictation history")?.kind, .dictation)
        XCTAssertEqual(SourceQuery.parse("dictation history meeting")?.filter, "meeting")
    }
}
