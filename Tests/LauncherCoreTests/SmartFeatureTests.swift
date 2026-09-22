import XCTest
@testable import LauncherCore

final class SmartFeatureTests: XCTestCase {
    func testUsageSummaryWindowsAndCost() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
        func day(_ offset: Int, _ input: Int) -> (String, JevDayUsage) {
            var usage = JevDayUsage(); usage.requests = 1; usage.inputTokens = input; usage.outputTokens = 20
            return (JevUsageLedger.key(for: calendar.date(byAdding: .day, value: -offset, to: now)!, calendar: calendar), usage)
        }
        let ledger = Dictionary(uniqueKeysWithValues: [day(0, 1000), day(6, 2000), day(7, 4000), day(40, 8000)])
        XCTAssertEqual(JevUsageLedger.summary(ledger, days: 7, now: now, calendar: calendar).inputTokens, 3000)
        XCTAssertEqual(JevUsageLedger.summary(ledger, days: 30, now: now, calendar: calendar).inputTokens, 7000)
        let all = JevUsageLedger.summary(ledger, days: nil, now: now, calendar: calendar)
        XCTAssertEqual(all.inputTokens, 15000)
        XCTAssertEqual(all.requests, 4)
        XCTAssertEqual(all.cost, 15000 * 0.042 / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(JevPricing.format(0.00063), "$0.000630")
        XCTAssertEqual(JevPricing.format(1.5), "$1.50")
    }

    func testLearnedIntentsNormalizeAndReplace() {
        var learned = LearnedIntents()
        learned.record("Make it bigger, please.", id: "window:maximize")
        XCTAssertEqual(learned.lookup("make it bigger"), "window:maximize")
        learned.record("make it bigger", id: "window:larger")
        XCTAssertEqual(learned.lookup("MAKE IT BIGGER"), "window:larger")
        learned.forget(id: "window:larger")
        XCTAssertNil(learned.lookup("make it bigger"))
        learned.record("a", id: "x")
        XCTAssertNil(learned.lookup("a"), "One-letter requests are not remembered.")
    }

    func testTimerQueries() {
        XCTAssertEqual(TimerQuery.parse("5m tea"), TimerQuery(seconds: 300, label: "tea"))
        XCTAssertEqual(TimerQuery.parse("timer 10 min"), TimerQuery(seconds: 600, label: ""))
        XCTAssertEqual(TimerQuery.parse("10 minute timer"), TimerQuery(seconds: 600, label: ""))
        XCTAssertEqual(TimerQuery.parse("remind me in 20 minutes to call Sam"), TimerQuery(seconds: 1200, label: "call Sam"))
        XCTAssertEqual(TimerQuery.parse("1h30m stretch"), TimerQuery(seconds: 5400, label: "stretch"))
        XCTAssertEqual(TimerQuery.parse("set a timer for 90 seconds"), TimerQuery(seconds: 90, label: ""))
        XCTAssertNil(TimerQuery.parse("10 m in ft"), "A conversion is not a timer.")
        XCTAssertNil(TimerQuery.parse("10 km"))
        XCTAssertNil(TimerQuery.parse("safari"))
        XCTAssertNil(TimerQuery.parse("48h"), "More than a day is refused.")
        XCTAssertEqual(TimerQuery.describe(5400), "1 h 30 min")
    }

    func testQueryRemainder() {
        XCTAssertEqual(QueryText.remainder(of: "search github for swift ui", removing: ["GitHub", "gh"]), "swift ui")
        XCTAssertEqual(QueryText.remainder(of: "youtube lofi beats please", removing: ["YouTube", "yt"]), "lofi beats")
        XCTAssertEqual(QueryText.remainder(of: "look up the moon on wikipedia", removing: ["Wikipedia", "wiki"]), "moon")
        XCTAssertEqual(QueryText.remainder(of: "gh", removing: ["GitHub", "gh"]), "")
    }

    func testAnswerSubstitution() {
        XCTAssertEqual(QueryText.substitutingAnswer("ans * 2", last: "1,240"), "(1240) * 2")
        XCTAssertNil(QueryText.substitutingAnswer("answer me", last: "12"))
        XCTAssertNil(QueryText.substitutingAnswer("ans + 1", last: nil))
        XCTAssertEqual(Calculator.evaluate(QueryText.substitutingAnswer("ans * 2", last: "120")!, locale: Locale(identifier: "en_GB")), "240")
    }

    func testSymbolSearch() {
        XCTAssertEqual(Symbols.query(":tada"), "tada")
        XCTAssertEqual(Symbols.query("emoji party"), "party")
        XCTAssertNil(Symbols.query(":3000"))
        XCTAssertNil(Symbols.query("emojify"))
        XCTAssertEqual(Symbols.search("tada").first?.character, "🎉")
        XCTAssertEqual(Symbols.search("command").first?.character, "⌘")
        XCTAssertTrue(Symbols.search("zzqx").isEmpty)
    }

    func testNaturalFileQueries() {
        let lastWeek = FileSearchQuery(text: "pdfs from last week in downloads")
        XCTAssertTrue(lastWeek.isValid, lastWeek.validationError ?? "")
        XCTAssertEqual(lastWeek.kind, .pdf)
        XCTAssertEqual(lastWeek.modified, .lastWeek)
        XCTAssertEqual(lastWeek.scope, .downloads)
        XCTAssertEqual(lastWeek.nameQuery, "")

        let screenshots = FileSearchQuery(text: "find my screenshots from yesterday")
        XCTAssertTrue(screenshots.isValid)
        XCTAssertEqual(screenshots.modified, .yesterday)
        XCTAssertEqual(screenshots.nameQuery, "screenshots")
        XCTAssertTrue(screenshots.matches(name: "Screenshot 2026-09-22.png", path: "/x/Screenshot 2026-09-22.png", isDirectory: false,
                                          modifiedDate: Date().addingTimeInterval(-86_400)))

        let month = FileSearchQuery(text: "documents i changed last month")
        XCTAssertTrue(month.isValid, month.validationError ?? "")
        XCTAssertEqual(month.kind, .document)
        XCTAssertEqual(month.modified, .lastMonth)

        // "Photos" is also an app, so it needs a file word. Jev can add one by choosing Find Files.
        XCTAssertFalse(FileSearchQuery(text: "photos from this week").isExplicitFileSearch)
        let thisWeek = FileSearchQuery(text: "find photos from this week")
        XCTAssertEqual(thisWeek.kind, .image)
        XCTAssertEqual(thisWeek.modified, .week)

        XCTAssertFalse(FileSearchQuery(text: "100 / 4").isExplicitFileSearch, "Division is not a path.")
        XCTAssertTrue(FileSearchQuery(text: "/Users").isExplicitFileSearch)
        // Everyday words stay launcher searches without file context.
        XCTAssertFalse(FileSearchQuery(text: "last week tonight").isExplicitFileSearch)
    }
}
