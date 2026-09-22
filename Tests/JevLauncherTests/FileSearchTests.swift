import XCTest
import LauncherCore
@testable import JevLauncher

final class FileSearchTests: XCTestCase {
    @MainActor func testSingleWordPredicateIsNotASingleChildCompound() {
        let predicate = FileSearch().predicate(for: FileSearchQuery(text: "invoice"))
        XCTAssertFalse(predicate is NSCompoundPredicate)
        XCTAssertTrue(predicate.evaluate(with: [NSMetadataItemFSNameKey: "invoice.pdf"]))
    }
    @MainActor func testTypeAndDateAreAppliedBeforeSpotlightResultLimit() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let predicate = FileSearch().predicate(for: FileSearchQuery(text: "kind:pdf modified:today"), now: now, calendar: calendar)
        XCTAssertTrue(predicate.evaluate(with: [NSMetadataItemFSNameKey: "invoice.pdf", NSMetadataItemFSContentChangeDateKey: now]))
        XCTAssertFalse(predicate.evaluate(with: [NSMetadataItemFSNameKey: "photo.png", NSMetadataItemFSContentChangeDateKey: now]))
        XCTAssertFalse(predicate.evaluate(with: [NSMetadataItemFSNameKey: "invoice.pdf", NSMetadataItemFSContentChangeDateKey: now.addingTimeInterval(-86400)]))
    }
    @MainActor func testRequestedFolderNarrowsConfiguredHome() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        let scopes = FileSearch().effectiveScopes(for: FileSearchQuery(text: "in:downloads"), configured: [home])
        XCTAssertEqual(scopes, [home.appendingPathComponent("Downloads").resolvingSymlinksInPath()])
    }
    @MainActor func testBroaderRequestedScopeCannotExpandConfiguredFolder() {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/JevScopeTest")
        let scopes = FileSearch().effectiveScopes(for: FileSearchQuery(text: "in:downloads"), configured: [root])
        XCTAssertEqual(scopes, [root])
    }
    @MainActor func testDirectPathCannotEscapeConfiguredFolderThroughParentOrSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let allowed = root.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt")
        try Data("test".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("link.txt"), withDestinationURL: outside)
        let search = FileSearch()
        for path in [allowed.path + "/../outside.txt", allowed.path + "/link.txt"] {
            var returned: [FileEntry]?
            search.search("\"" + path + "\"", folders: [allowed.path]) { returned = $0 }
            XCTAssertEqual(returned, [])
        }
    }
    @MainActor func testKindsWithATypeUseTheContentTypeTree() {
        let image = FileSearch().predicate(for: FileSearchQuery(text: "kind:image"))
        XCTAssertTrue(image.predicateFormat.contains("kMDItemContentTypeTree == \"public.image\""), image.predicateFormat)
        XCTAssertTrue(image.evaluate(with: [NSMetadataItemFSNameKey: "photo.png"]))
        let pdf = FileSearch().predicate(for: FileSearchQuery(text: "kind:pdf"))
        XCTAssertTrue(pdf.predicateFormat.contains("com.adobe.pdf"))
        XCTAssertEqual(FileSearch.contentTypes(for: .video), ["public.movie"])
        XCTAssertEqual(FileSearch.contentTypes(for: .audio), ["public.audio"])
        XCTAssertEqual(FileSearch.contentTypes(for: .document), [])
        let folder = FileSearch().predicate(for: FileSearchQuery(text: "kind:folder"))
        XCTAssertFalse(folder.predicateFormat.contains("kMDItemContentTypeTree"))
    }
    @MainActor func testContentTypeAcceptsUnlistedRawExtensionButKeepsOtherFilters() {
        let query = FileSearchQuery(text: "kind:image beach")
        let raw = ["public.camera-raw-image", "public.image", "public.data", "public.item"]
        XCTAssertTrue(FileSearch.accepts(query: query, name: "beach.3fr", path: "/p/beach.3fr", isDirectory: false, modifiedDate: nil) { raw })
        XCTAssertFalse(FileSearch.accepts(query: query, name: "beach.3fr", path: "/p/beach.3fr", isDirectory: false, modifiedDate: nil) { [] })
        XCTAssertFalse(FileSearch.accepts(query: query, name: "forest.cr2", path: "/p/forest.cr2", isDirectory: false, modifiedDate: nil) { raw })
        XCTAssertTrue(FileSearch.accepts(query: query, name: "beach.jpg", path: "/p/beach.jpg", isDirectory: false, modifiedDate: nil) { [] })

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let today = FileSearchQuery(text: "kind:image modified:today")
        XCTAssertFalse(FileSearch.accepts(query: today, name: "a.nef", path: "/p/a.nef", isDirectory: false,
                                          modifiedDate: now.addingTimeInterval(-3 * 86400), now: now, calendar: calendar) { raw })
        XCTAssertTrue(FileSearch.accepts(query: today, name: "a.nef", path: "/p/a.nef", isDirectory: false,
                                         modifiedDate: now, now: now, calendar: calendar) { raw })
    }
    @MainActor func testOlderExactOrPrefixNameMatchesSurviveTheRecentCap() {
        let names = (0..<1_000).map { index -> String in
            switch index {
            case 900: return "report.pdf"
            case 950: return "Report final.docx"
            default: return "annual report \(index).txt"
            }
        }
        let indices = FileSearch.candidateIndices(total: names.count, recentLimit: 640, nameScanLimit: 8_000, extraLimit: 40, nameQuery: "report") { names[$0] }
        XCTAssertEqual(indices.count, 642)
        XCTAssertEqual(Array(indices.suffix(2)), [900, 950])
        XCTAssertEqual(FileSearch.candidateIndices(total: names.count, recentLimit: 640, nameScanLimit: 0, extraLimit: 40, nameQuery: "report") { names[$0] }.count, 640)
        XCTAssertEqual(FileSearch.candidateIndices(total: names.count, recentLimit: 640, nameScanLimit: 8_000, extraLimit: 40, nameQuery: "") { names[$0] }.count, 640)
        XCTAssertEqual(FileSearch.candidateIndices(total: 10, recentLimit: 640, nameScanLimit: 8_000, extraLimit: 40, nameQuery: "x") { _ in "x" }, Array(0..<10))
        XCTAssertEqual(FileSearch.nameRelevance(name: "Report.PDF", nameQuery: "report.pdf"), 1)
        XCTAssertEqual(FileSearch.nameRelevance(name: "annual report", nameQuery: "report"), 0.65)
    }
    func testMixedSearchSkipsLibraryHiddenAndBuildFolders() {
        let home = "/Users/test"
        let mixed = FileSearchQuery(text: "report")
        XCTAssertFalse(mixed.isExplicitFileSearch)
        XCTAssertFalse(FileSearch.isNoise(home + "/Documents/report.pdf", query: mixed, home: home))
        for path in [home + "/Library/Application Support/Chrome/report", home + "/Library",
                     home + "/Dev/.cache/report.txt", home + "/.report", home + "/Dev/app/node_modules/report.js",
                     home + "/Dev/app/dist/report.html", home + "/Dev/app/build/report.o", home + "/Dev/app/.build/report",
                     home + "/Dev/app/DerivedData/report", home + "/Dev/app/Pods/report.h", home + "/Dev/app/vendor/report.rb",
                     home + "/Dev/app/__pycache__/report.pyc", "/Library/Caches/x/report", home + "/Dev/.git/report",
                     home + "/go/pkg/mod/golang.org/x/crypto@v0.54.0/pkcs12/safebags.go", home + "/Dev/app/venv/lib/site-packages/report.py"] {
            XCTAssertTrue(FileSearch.isNoise(path, query: mixed, home: home), path)
        }
        XCTAssertFalse(FileSearch.isNoise("/Users/testing/Library/report", query: mixed, home: home), "Only this home's Library.")
    }
    func testExplicitSearchKeepsLibraryAndBuildButSkipsHiddenUnlessNamed() {
        let home = "/Users/test"
        let explicit = FileSearchQuery(text: "find file report")
        XCTAssertTrue(explicit.isExplicitFileSearch)
        XCTAssertFalse(FileSearch.isNoise(home + "/Library/Application Support/report", query: explicit, home: home))
        XCTAssertFalse(FileSearch.isNoise(home + "/Dev/app/dist/report.html", query: explicit, home: home))
        XCTAssertTrue(FileSearch.isNoise(home + "/Dev/.cache/report.txt", query: explicit, home: home))
        XCTAssertTrue(FileSearch.isNoise(home + "/Dev/app/node_modules/report.js", query: explicit, home: home))
        XCTAssertTrue(FileSearch.isNoise("/Library/Caches/report", query: explicit, home: home))
        let dotName = FileSearchQuery(text: "find file .env")
        XCTAssertTrue(FileSearch.targetsHidden(dotName))
        XCTAssertFalse(FileSearch.isNoise(home + "/Dev/app/.env", query: dotName, home: home))
        let dotScope = FileSearchQuery(text: "in:~/.config settings")
        XCTAssertTrue(dotScope.isExplicitFileSearch)
        XCTAssertFalse(FileSearch.isNoise(home + "/.config/app/settings.json", query: dotScope, home: home))
        XCTAssertTrue(FileSearch.isNoise(home + "/.config/.git/settings", query: dotScope, home: home))
    }
}
