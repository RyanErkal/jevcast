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

    func testWordPrefixBeatsFuzzyNoise() {
        let chrome = SearchRanking.score(query: "ch", title: "Google Chrome") ?? 0
        let noise = SearchRanking.score(query: "ch", title: "Launchpad") ?? 0
        XCTAssertGreaterThanOrEqual(chrome, 0.75)
        XCTAssertGreaterThan(chrome, noise)
        XCTAssertGreaterThan(SearchRanking.score(query: "c", title: "Google Chrome") ?? 0, 0.7)
        // A whole word still ranks above a partial word.
        XCTAssertGreaterThan(
            SearchRanking.score(query: "chrome", title: "Google Chrome") ?? 0,
            SearchRanking.score(query: "chr", title: "Google Chrome") ?? 0
        )
    }

    func testCamelCaseWords() {
        XCTAssertGreaterThanOrEqual(SearchRanking.score(query: "time", title: "FaceTime") ?? 0, 0.75)
        XCTAssertGreaterThanOrEqual(SearchRanking.score(query: "movie", title: "iMovie") ?? 0, 0.75)
        XCTAssertEqual(SearchRanking.score(query: "imovie", title: "iMovie"), 1.0)
        XCTAssertEqual(SearchRanking.score(query: "ft", title: "FaceTime"), 0.55)
    }

    func testAcronymPrefixBeatsFuzzy() {
        for query in ["vs", "vsc"] {
            let code = SearchRanking.score(query: query, title: "Visual Studio Code") ?? 0
            let fuzzy = SearchRanking.score(query: query, title: "Devices") ?? 0
            XCTAssertGreaterThan(code, fuzzy, query)
            XCTAssertGreaterThanOrEqual(code, 0.5, query)
        }
    }

    func testTierOrdering() {
        let tiers = [
            SearchRanking.score(query: "google chrome", title: "Google Chrome"),
            SearchRanking.score(query: "goo", title: "Google Chrome"),
            SearchRanking.score(query: "chro", title: "Google Chrome"),
            SearchRanking.score(query: "gc", title: "Google Chrome"),
            SearchRanking.score(query: "hrom", title: "Google Chrome"),
            SearchRanking.score(query: "gre", title: "Google Chrome")
        ].map { $0 ?? 0 }
        XCTAssertEqual(tiers, tiers.sorted(by: >))
        XCTAssertEqual(Set(tiers).count, tiers.count)
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

    func testPlainNumbersAreNotCalculations() {
        for text in ["1", "42", "-5", "+3", " 7 ", "1,000", "3.5"] {
            XCTAssertNil(Calculator.evaluate(text, locale: us), text)
        }
        XCTAssertEqual(Calculator.evaluate("(5)", locale: us), "5")
        XCTAssertEqual(Calculator.evaluate("-5 + 0", locale: us), "-5")
    }

    func testFormattingKeepsPrecision() {
        XCTAssertEqual(Calculator.evaluate("2^40", locale: us), "1099511627776")
        XCTAssertEqual(Calculator.evaluate("2^52 + 1", locale: us), "4503599627370497")
        XCTAssertEqual(Calculator.evaluate("0.1 + 0.2", locale: us), "0.3")
        XCTAssertEqual(Calculator.evaluate("1 / 3", locale: us), "0.333333333333333")
        XCTAssertEqual(Calculator.evaluate("2^60", locale: us), "1.15292150460685e+18")
    }

    func testSpotlightPercent() {
        XCTAssertEqual(Calculator.evaluate("100+10%", locale: us), "110")
        XCTAssertEqual(Calculator.evaluate("100-10%", locale: us), "90")
        XCTAssertEqual(Calculator.evaluate("50*10%", locale: us), "5")
        XCTAssertEqual(Calculator.evaluate("10%", locale: us), "0.1")
    }

    func testLocaleSeparators() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(Calculator.evaluate("1,5+1", locale: german), "2,5")
        XCTAssertEqual(Calculator.evaluate("1.000+1", locale: german), "1001")
        XCTAssertEqual(Calculator.evaluate("1,000+1", locale: us), "1001")
        XCTAssertEqual(Calculator.evaluate("1,234,567.5*2", locale: us), "2469135")
        XCTAssertNil(Calculator.evaluate("1,5+1", locale: us))
    }

    func testImplicitMultiplication() {
        XCTAssertEqual(Calculator.evaluate("2(3)", locale: us), "6")
        XCTAssertEqual(Calculator.evaluate("(1+2)(3)", locale: us), "9")
        XCTAssertEqual(Calculator.evaluate("2 (3 + 1)", locale: us), "8")
    }

    func testUnitConversions() {
        XCTAssertEqual(Calculator.evaluate("10 km in mi", locale: us), "6.2137 mi")
        XCTAssertEqual(Calculator.evaluate("5 ft to cm", locale: us), "152.4 cm")
        XCTAssertEqual(Calculator.evaluate("100 f to c", locale: us), "37.7778 °C")
        XCTAssertEqual(Calculator.evaluate("3 kg in lb", locale: us), "6.6139 lb")
        XCTAssertEqual(Calculator.evaluate("1 gb in mb", locale: us), "1000 MB")
        XCTAssertEqual(Calculator.evaluate("90 min in h", locale: us), "1.5 h")
        XCTAssertEqual(Calculator.evaluate("12 in in cm", locale: us), "30.48 cm")
        XCTAssertEqual(Calculator.evaluate("-40 °C to °F", locale: us), "-40 °F")
        XCTAssertEqual(Calculator.evaluate("100 km/h in mph", locale: us), "62.1371 mph")
        XCTAssertEqual(Calculator.evaluate("1 acre in m2", locale: us), "4046.8564 m²")
        XCTAssertEqual(Calculator.evaluate("2 l in ml", locale: us), "2000 mL")
        XCTAssertEqual(Calculator.evaluate("1,5 km in m", locale: Locale(identifier: "de_DE")), "1500 m")
        XCTAssertNil(Calculator.evaluate("1 kg in km", locale: us))
        XCTAssertNil(Calculator.evaluate("put window in left half", locale: us))
        XCTAssertNil(Calculator.evaluate("10 usd in eur", locale: us))
    }

    private let us = Locale(identifier: "en_US")
}
