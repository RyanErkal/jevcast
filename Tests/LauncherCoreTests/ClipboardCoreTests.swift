import XCTest
@testable import LauncherCore

final class ClipClassifierTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(ClipClassifier.classify("https://github.com/x").kind, .link)
        XCTAssertEqual(ClipClassifier.classify("www.apple.com").kind, .link)
        XCTAssertEqual(ClipClassifier.classify("sam@example.com").kind, .email)
        XCTAssertEqual(ClipClassifier.classify("+44 20 7946 0958").kind, .phone)
        XCTAssertEqual(ClipClassifier.classify("(555) 123-4567").kind, .phone)
        XCTAssertEqual(ClipClassifier.classify("1234567").kind, .number)
        XCTAssertEqual(ClipClassifier.classify("£1,240.00").kind, .number)
        XCTAssertEqual(ClipClassifier.classify("#5B8CFF").kind, .color)
        XCTAssertEqual(ClipClassifier.classify("rgb(12, 34, 56)").kind, .color)
        XCTAssertEqual(ClipClassifier.classify("hsl(210, 50%, 40%)").kind, .color)
        XCTAssertEqual(ClipClassifier.classify("Meeting at 10\nRoom 4B").kind, .text)
        XCTAssertEqual(ClipClassifier.classify("Just a sentence.").kind, .text)
        XCTAssertEqual(ClipClassifier.classify("#hashtag").kind, .text)
    }

    func testCodeLanguages() {
        XCTAssertEqual(ClipClassifier.classify("import SwiftUI\nstruct A: View {\n  var body: some View { Text(\"a\") }\n}").language, "Swift")
        XCTAssertEqual(ClipClassifier.classify("def main():\n    import os\n    print(os.name)").language, "Python")
        XCTAssertEqual(ClipClassifier.classify("const a = 1;\nfunction b() { return a; }").language, "JavaScript")
        XCTAssertEqual(ClipClassifier.classify("SELECT id\nFROM users WHERE id = 1;").language, "SQL")
        XCTAssertEqual(ClipClassifier.classify("{\n  \"a\": 1\n}").language, "JSON")
        XCTAssertEqual(ClipClassifier.classify("{\n  \"a\": 1\n}").kind, .code)
        XCTAssertNil(ClipClassifier.codeLanguage("Dear Sam,\nThanks for the call.\nBest, Alex"))
    }

    func testColorConversions() throws {
        let hex = try XCTUnwrap(ClipColor.parse("#f00"))
        XCTAssertEqual(hex.hexString, "#FF0000")
        XCTAssertEqual(hex.rgbString, "rgb(255, 0, 0)")
        XCTAssertEqual(hex.hslString, "hsl(0, 100%, 50%)")
        XCTAssertEqual(ClipColor.parse("hsl(120, 100%, 25%)")?.hexString, "#008000")
        XCTAssertEqual(ClipColor.parse("rgba(0, 0, 255, 0.5)")?.rgbString, "rgba(0, 0, 255, 0.5)")
        XCTAssertEqual(ClipColor.parse("#11223380")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(ClipColor.parse("#12345"))
        XCTAssertNil(ClipColor.parse("rgb(300, 0, 0)"))
        XCTAssertNil(ClipColor.parse("cmyk(1, 2, 3)"))
    }
}

final class ClipTransformTests: XCTestCase {
    func testCaseAndLines() throws {
        XCTAssertEqual(try ClipTransform.uppercase.apply("abc"), "ABC")
        XCTAssertEqual(try ClipTransform.lowercase.apply("ABC"), "abc")
        XCTAssertEqual(try ClipTransform.titleCase.apply("hello big world"), "Hello Big World")
        XCTAssertEqual(try ClipTransform.trim.apply("  a b \n"), "a b")
        XCTAssertEqual(try ClipTransform.removeLineBreaks.apply("a\n b\n\nc"), "a b c")
        XCTAssertEqual(try ClipTransform.sortLines.apply("b\na10\na2"), "a2\na10\nb")
        XCTAssertEqual(try ClipTransform.removeDuplicateLines.apply("a\nb\na\nc\nb"), "a\nb\nc")
        XCTAssertEqual(try ClipTransform.count.apply("one two\nthree"), "13 characters · 3 words · 2 lines")
    }

    func testJSON() throws {
        XCTAssertEqual(try ClipTransform.jsonMinify.apply("{ \"a\" : [1, 2] }"), "{\"a\":[1,2]}")
        XCTAssertEqual(try ClipTransform.jsonPretty.apply("{\"b\":1,\"a\":\"x/y\"}"), "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
        XCTAssertThrowsError(try ClipTransform.jsonPretty.apply("{a: 1}"))
        XCTAssertThrowsError(try ClipTransform.jsonMinify.apply("not json"))
    }

    func testEncodings() throws {
        XCTAssertEqual(try ClipTransform.urlEncode.apply("a b&c=d/é"), "a%20b%26c%3Dd%2F%C3%A9")
        XCTAssertEqual(try ClipTransform.urlDecode.apply("a%20b+c"), "a b c")
        XCTAssertThrowsError(try ClipTransform.urlDecode.apply("%E0%A4%A"))
        XCTAssertEqual(try ClipTransform.base64Encode.apply("hello"), "aGVsbG8=")
        XCTAssertEqual(try ClipTransform.base64Decode.apply("aGVsbG8"), "hello")
        XCTAssertThrowsError(try ClipTransform.base64Decode.apply("***"))
        XCTAssertThrowsError(try ClipTransform.base64Decode.apply("/w=="))
    }

    func testEmptyInputThrows() {
        for transform in ClipTransform.allCases { XCTAssertThrowsError(try transform.apply(""), transform.rawValue) }
    }
}

final class ClipRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func entry(_ minutesAgo: Double, pinned: Bool = false, size: Int64 = 10) -> ClipEntry {
        ClipEntry(hash: UUID().uuidString, kind: .text, copiedAt: now.addingTimeInterval(-minutesAgo * 60), pinned: pinned, text: "x", byteSize: size)
    }

    func testAgeRemovesOldUnpinnedOnly() {
        let fresh = entry(10), old = entry(60 * 24 * 8), oldPinned = entry(60 * 24 * 8, pinned: true)
        let removed = ClipRetention(keepDays: 7, maxItems: 100, maxBytes: 1_000).expired([fresh, old, oldPinned], now: now)
        XCTAssertEqual(removed, [old.id])
        XCTAssertTrue(ClipRetention(keepDays: 0, maxItems: 100, maxBytes: 1_000).expired([old], now: now).isEmpty)
    }

    func testCountKeepsNewestAndPins() {
        let entries = (0..<5).map { entry(Double($0)) } + [entry(100, pinned: true)]
        let removed = ClipRetention(keepDays: 0, maxItems: 3, maxBytes: 1_000).expired(entries, now: now)
        XCTAssertEqual(removed, Set(entries[3...4].map(\.id)))
    }

    func testSizeRemovesOldestUnpinned() {
        let entries = [entry(1, size: 40), entry(2, size: 40), entry(3, pinned: true, size: 40), entry(4, size: 40)]
        let removed = ClipRetention(keepDays: 0, maxItems: 100, maxBytes: 100).expired(entries, now: now)
        XCTAssertEqual(removed, [entries[3].id, entries[1].id])
    }

    func testSettingsDecodeKeepsDefaultsForMissingKeys() throws {
        let decoded = try JSONDecoder().decode(ClipboardSettings.self, from: Data("{\"enabled\":false}".utf8))
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.maxItems, 500)
        XCTAssertEqual(decoded.keepDays, 30)
        XCTAssertTrue(decoded.ignores("com.bitwarden.desktop"))
        XCTAssertFalse(decoded.ignores("com.apple.Notes"))
    }
}

final class ClipSearchTests: XCTestCase {
    private func text(_ value: String, pinned: Bool = false, ocr: String? = nil, source: String? = nil) -> ClipEntry {
        let (kind, language) = ClipClassifier.classify(value)
        return ClipEntry(hash: value, kind: kind, copiedAt: Date(), pinned: pinned, text: value, language: language, ocrText: ocr, sourceName: source)
    }

    func testQueryWordsMapToChips() {
        XCTAssertEqual(ClipQuery.parse("link github"), ClipQuery(filter: .links, words: ["github"]))
        XCTAssertEqual(ClipQuery.parse("code"), ClipQuery(filter: .code))
        XCTAssertEqual(ClipQuery.parse("colours"), ClipQuery(filter: .colors))
        XCTAssertEqual(ClipQuery.parse("emails"), ClipQuery(kind: .email))
        XCTAssertEqual(ClipQuery.parse("Invoice 42"), ClipQuery(words: ["invoice", "42"]))
    }

    func testFilterFindsTextOCRFileNamesSourceAndHost() {
        var image = ClipEntry(hash: "i", kind: .image, copiedAt: Date(), image: ClipImageInfo(width: 1, height: 1, uti: "public.png", byteSize: 1))
        image.ocrText = "Quarterly Revenue"
        let file = ClipEntry(hash: "f", kind: .files, copiedAt: Date(), text: "/tmp/Budget.numbers",
                             files: [ClipFile(path: "/tmp/Budget.numbers", name: "Budget.numbers", category: .document)])
        let entries = [text("hello world", source: "Notes"), text("https://github.com/a"), image, file, text("#fff", pinned: true)]
        let keys = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, ClipSearch.key(for: $0)) })
        func find(_ query: String, chip: ClipFilter = .all) -> [ClipEntry] {
            ClipSearch.filter(entries, keys: keys, chip: chip, query: ClipQuery.parse(query))
        }
        XCTAssertEqual(find("revenue").map(\.id), [image.id])
        XCTAssertEqual(find("budget").map(\.id), [file.id])
        XCTAssertEqual(find("notes").first?.text, "hello world")
        XCTAssertEqual(find("github.com").count, 1)
        XCTAssertEqual(find("").first?.id, entries[4].id, "pinned first")
        XCTAssertEqual(find("", chip: .images).map(\.id), [image.id])
        XCTAssertEqual(find("links").count, 1)
        XCTAssertEqual(find("", chip: .colors).count, 1)
        XCTAssertEqual(find("", chip: .pinned).count, 1)
        XCTAssertTrue(find("zzz").isEmpty)
    }

    func testJoinedKeepsOrderAndSkipsImages() {
        let image = ClipEntry(hash: "i", kind: .image, copiedAt: Date())
        let file = ClipEntry(hash: "f", kind: .files, copiedAt: Date(), files: [ClipFile(path: "/a/b.txt", name: "b.txt", category: .document)])
        XCTAssertEqual(ClipSearch.joined([text("one"), image, file, text("two")]), "one\n/a/b.txt\ntwo")
    }

    /// 2000 entries filtered by a word must stay well inside one frame.
    func testFilteringTwoThousandEntriesIsFast() {
        let words = ["invoice", "meeting", "launch", "design", "budget", "travel", "report", "draft"]
        let entries = (0..<2000).map { index -> ClipEntry in
            let body = (0..<40).map { words[($0 * 7 + index) % words.count] }.joined(separator: " ")
            return text("Entry \(index) \(body)\nline two \(index)", pinned: index % 50 == 0, ocr: index % 10 == 0 ? "scanned \(index)" : nil)
        }
        let keys = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, ClipSearch.key(for: $0)) })
        let start = CFAbsoluteTimeGetCurrent()
        let found = ClipSearch.filter(entries, keys: keys, chip: .all, query: ClipQuery.parse("budget report"))
        let chip = ClipSearch.filter(entries, keys: keys, chip: .text, query: ClipQuery.parse("scanned 1"))
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[clip perf] filtered 2000 entries twice in \(String(format: "%.2f", elapsed)) ms")
        XCTAssertFalse(found.isEmpty)
        XCTAssertFalse(chip.isEmpty)
        XCTAssertLessThan(elapsed, 50)
    }
}
