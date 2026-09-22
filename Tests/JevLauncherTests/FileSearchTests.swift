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
}
