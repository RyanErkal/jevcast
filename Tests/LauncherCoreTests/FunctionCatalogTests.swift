import XCTest
@testable import LauncherCore

final class FunctionCatalogTests: XCTestCase {
    func testParsesPrefixes() {
        XCTAssertEqual(PrefixQuery.parse("/cal"), .functions("cal"))
        XCTAssertEqual(PrefixQuery.parse("/"), .functions(""))
        XCTAssertEqual(PrefixQuery.parse("$ deploy"), .library("deploy"))
        XCTAssertNil(PrefixQuery.parse("/Users/me"))
        XCTAssertNil(PrefixQuery.parse("~/Downloads"))
        XCTAssertNil(PrefixQuery.parse("calendar"))
        XCTAssertNil(PrefixQuery.parse(""))
    }

    func testFiltersByTitleAndKeyword() {
        let all = FunctionCatalog.builtIn
        XCTAssertEqual(FunctionCatalog.search("cal", in: all).first?.id, "view:calendar")
        XCTAssertTrue(FunctionCatalog.search("inbox", in: all).contains { $0.id == "view:mail" })
        XCTAssertEqual(FunctionCatalog.search("left half", in: all).first?.id, "window:left-half")
        XCTAssertEqual(FunctionCatalog.search("", in: all).count, all.count)
        XCTAssertTrue(FunctionCatalog.search("zzqxv", in: all).isEmpty)
    }

    func testEntriesAreUniqueAndSummarised() {
        let all = FunctionCatalog.builtIn
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(all.allSatisfy { !$0.summary.isEmpty && !$0.summary.contains("\n") })
        XCTAssertTrue(all.contains { $0.id == "settings:ai" && $0.group == .settings })
    }
}
