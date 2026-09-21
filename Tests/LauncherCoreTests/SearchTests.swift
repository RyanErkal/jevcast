import XCTest
@testable import LauncherCore

final class SearchTests: XCTestCase {
    func testExactAndPrefixRanking() {
        XCTAssertEqual(SearchRanking.score(query: "Safari", title: "Safari"), 1.0)

        let prefix = SearchRanking.score(query: "saf", title: "Safari")
        let token = SearchRanking.score(query: "browser", title: "Safari Browser")
        XCTAssertEqual(prefix, 0.90)
        XCTAssertNotNil(token)
        XCTAssertGreaterThan(prefix ?? 0, token ?? 0)
    }

    func testAliasesAndDiacriticsMatch() {
        let score = SearchRanking.score(
            query: "resume",
            title: "Open Résumé",
            aliases: ["CV"]
        )
        XCTAssertEqual(score, 1.0)
        XCTAssertEqual(SearchRanking.score(query: "cafe", title: "Café"), 1.0)
    }

    func testCommandPrefixesAndSpokenWindowPhrases() {
        XCTAssertEqual(
            SearchRanking.score(
                query: "open launch switch to find safari",
                title: "Safari"
            ),
            1.0
        )

        let left = SearchRanking.score(
            query: "move this to the left half",
            title: "Left Half"
        )
        let right = SearchRanking.score(
            query: "move this to the left half",
            title: "Right Half"
        )
        XCTAssertEqual(left, 1.0)
        XCTAssertGreaterThan(left ?? 0, right ?? 0)
    }

    func testTokenAndFuzzyRanking() {
        let token = SearchRanking.score(query: "left half", title: "Snap Left Half")
        let acronym = SearchRanking.score(query: "wm", title: "Window Manager")
        let unrelated = SearchRanking.score(query: "left half", title: "Calculator")

        XCTAssertNotNil(token)
        XCTAssertNotNil(acronym)
        XCTAssertGreaterThan(token ?? 0, acronym ?? 0)
        XCTAssertNil(unrelated)
    }
}

final class CalculatorTests: XCTestCase {
    func testPrecedenceAndParentheses() {
        XCTAssertEqual(Calculator.evaluate("2 + 3 * 4"), "14")
        XCTAssertEqual(Calculator.evaluate("(2 + 3) * 4"), "20")
        XCTAssertEqual(Calculator.evaluate("8 / 2 - 1"), "3")
    }

    func testUnaryAndExponentPrecedence() {
        XCTAssertEqual(Calculator.evaluate("-2^2"), "-4")
        XCTAssertEqual(Calculator.evaluate("(-2)^2"), "4")
        XCTAssertEqual(Calculator.evaluate("2^-2"), "0.25")
        XCTAssertEqual(Calculator.evaluate("2^3^2"), "512")
    }

    func testPercentAndUnicodeOperators() {
        XCTAssertEqual(Calculator.evaluate("50%"), "0.5")
        XCTAssertEqual(Calculator.evaluate("200 × 10%"), "20")
        XCTAssertEqual(Calculator.evaluate("8 ÷ 2 − 1"), "3")
    }

    func testInvalidAndUnsafeExpressionsAreRejected() {
        XCTAssertNil(Calculator.evaluate("1 / 0"))
        XCTAssertNil(Calculator.evaluate("sqrt(4)"))
        XCTAssertNil(Calculator.evaluate("1e3"))
        XCTAssertNil(Calculator.evaluate("(2 + 3"))
        XCTAssertNil(Calculator.evaluate("1" + String(repeating: "0", count: 101)))
    }
}
