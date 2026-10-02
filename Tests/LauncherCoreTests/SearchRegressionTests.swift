import XCTest
@testable import LauncherCore

final class SearchRankingRegressionTests: XCTestCase {
    func testUnmatchedWordsDoNotReceiveStrongScores() {
        for (query, title) in [("safari xyz", "Safari"), ("abc safari def", "Safari"), ("left banana half", "Left Half")] {
            XCTAssertLessThan(SearchRanking.score(query: query, title: title) ?? 0, 0.4)
        }
    }

    func testCompactNameIsAnExactMatch() {
        XCTAssertEqual(SearchRanking.score(query: "t3code nightly", title: "T3 Code (Nightly)"), 1)
        XCTAssertEqual(SearchRanking.score(query: "wifi", title: "Wi-Fi"), 1)
    }
}
