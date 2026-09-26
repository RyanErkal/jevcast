import XCTest
@testable import LauncherCore

final class RRuleTests: XCTestCase {
    let london = TimeZone(identifier: "Europe/London")!

    func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    func local(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = london; f.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // Anchor: Wed 2026-09-23 12:00 BST.
    lazy var anchor = date("2026-09-23T11:00:00Z")

    func next(_ rule: String, after: String, count: Int) throws -> [String] {
        try RRule(rule).occurrences(after: date(after), anchor: anchor, timeZone: london, limit: count).map(local)
    }

    func testRealRulesSummaries() throws {
        let cases: [(String, String)] = [
            ("RRULE:FREQ=WEEKLY;BYDAY=MO,TH,SA;BYHOUR=4;BYMINUTE=0", "Mon, Thu, Sat at 04:00"),
            ("RRULE:FREQ=WEEKLY;BYHOUR=4;BYMINUTE=0;BYDAY=SU,MO,TU,WE,TH,FR,SA", "Daily at 04:00"),
            ("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=4;BYMINUTE=30", "Weekdays at 04:30"),
            ("RRULE:FREQ=DAILY;BYHOUR=8,20;BYMINUTE=30", "Daily at 08:30 and 20:30"),
            ("RRULE:FREQ=WEEKLY;BYHOUR=4;BYMINUTE=0;BYDAY=SA", "Sat at 04:00"),
            ("RRULE:FREQ=DAILY;BYHOUR=4;BYMINUTE=20", "Daily at 04:20"),
            ("RRULE:FREQ=HOURLY;INTERVAL=4", "Every 4 hours"),
        ]
        for (text, summary) in cases { XCTAssertEqual(try RRule(text).summary(), summary, text) }
    }

    func testWeeklyMoThSa() throws {
        XCTAssertEqual(try next("RRULE:FREQ=WEEKLY;BYDAY=MO,TH,SA;BYHOUR=4;BYMINUTE=0", after: "2026-09-23T11:00:00Z", count: 4),
                       ["Thu 2026-09-24 04:00", "Sat 2026-09-26 04:00", "Mon 2026-09-28 04:00", "Thu 2026-10-01 04:00"])
    }

    func testEveryDayAcrossAutumnDST() throws {
        // BST ends Sun 2026-10-25 02:00. Wall time stays 04:00; UTC shifts by an hour.
        let rule = try RRule("RRULE:FREQ=WEEKLY;BYHOUR=4;BYMINUTE=0;BYDAY=SU,MO,TU,WE,TH,FR,SA")
        let dates = rule.occurrences(after: date("2026-10-23T12:00:00Z"), anchor: anchor, timeZone: london, limit: 4)
        XCTAssertEqual(dates.map(local), ["Sat 2026-10-24 04:00", "Sun 2026-10-25 04:00", "Mon 2026-10-26 04:00", "Tue 2026-10-27 04:00"])
        XCTAssertEqual(dates[0], date("2026-10-24T03:00:00Z"))
        XCTAssertEqual(dates[1], date("2026-10-25T04:00:00Z"))
    }

    func testWeekdays() throws {
        XCTAssertEqual(try next("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=4;BYMINUTE=30", after: "2026-09-25T12:00:00Z", count: 2),
                       ["Mon 2026-09-28 04:30", "Tue 2026-09-29 04:30"])
    }

    func testTwiceDaily() throws {
        XCTAssertEqual(try next("RRULE:FREQ=DAILY;BYHOUR=8,20;BYMINUTE=30", after: "2026-09-24T07:30:00Z", count: 3),
                       ["Thu 2026-09-24 20:30", "Fri 2026-09-25 08:30", "Fri 2026-09-25 20:30"])
    }

    func testSaturdayOnly() throws {
        XCTAssertEqual(try next("RRULE:FREQ=WEEKLY;BYHOUR=4;BYMINUTE=0;BYDAY=SA", after: "2026-09-26T03:00:00Z", count: 2),
                       ["Sat 2026-10-03 04:00", "Sat 2026-10-10 04:00"])
    }

    func testDaily0420() throws {
        XCTAssertEqual(try next("RRULE:FREQ=DAILY;BYHOUR=4;BYMINUTE=20", after: "2026-09-23T11:00:00Z", count: 1), ["Thu 2026-09-24 04:20"])
    }

    func testHourlyUsesElapsedTimeAcrossDST() throws {
        let rule = try RRule("RRULE:FREQ=HOURLY;INTERVAL=4")
        let a = date("2026-10-24T22:00:00Z")
        let dates = rule.occurrences(after: a, anchor: anchor, timeZone: london, limit: 3)
        // Anchor 11:00Z, step 4 h: 23:00Z, 03:00Z, 07:00Z, regardless of the 25 Oct change.
        XCTAssertEqual(dates, [date("2026-10-24T23:00:00Z"), date("2026-10-25T03:00:00Z"), date("2026-10-25T07:00:00Z")])
    }

    func testNonexistentTimeSkippedAndRepeatedTimeOnce() throws {
        let rule = try RRule("FREQ=DAILY;BYHOUR=1;BYMINUTE=30")
        // Spring: 2026-03-29 01:30 does not exist in London.
        let spring = rule.occurrences(after: date("2026-03-27T12:00:00Z"), anchor: date("2026-01-01T00:00:00Z"), timeZone: london, limit: 3)
        XCTAssertEqual(spring.map(local), ["Sat 2026-03-28 01:30", "Mon 2026-03-30 01:30", "Tue 2026-03-31 01:30"])
        // Autumn: 2026-10-25 01:30 happens twice; it fires once.
        let autumn = rule.occurrences(after: date("2026-10-24T12:00:00Z"), anchor: date("2026-01-01T00:00:00Z"), timeZone: london, limit: 2)
        XCTAssertEqual(autumn.map(local), ["Sun 2026-10-25 01:30", "Mon 2026-10-26 01:30"])
        XCTAssertEqual(autumn[1].timeIntervalSince(autumn[0]), 25 * 3600)
    }

    func testIntervals() throws {
        let everyOtherDay = try RRule("FREQ=DAILY;INTERVAL=2;BYHOUR=9;BYMINUTE=0")
        XCTAssertEqual(everyOtherDay.occurrences(after: anchor, anchor: anchor, timeZone: london, limit: 2).map(local),
                       ["Fri 2026-09-25 09:00", "Sun 2026-09-27 09:00"])
        let fortnightly = try RRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;BYHOUR=9;BYMINUTE=0")
        XCTAssertEqual(fortnightly.occurrences(after: anchor, anchor: anchor, timeZone: london, limit: 2).map(local),
                       ["Mon 2026-10-05 09:00", "Mon 2026-10-19 09:00"])
    }

    func testRejectsInvalid() {
        for bad in ["", "FREQ=MONTHLY", "FREQ=DAILY;COUNT=3", "FREQ=DAILY;BYHOUR=24", "FREQ=DAILY;INTERVAL=0", "BYHOUR=4",
                    "FREQ=DAILY;BYDAY=XX", "FREQ=DAILY;FREQ=DAILY", "FREQ=DAILY;;", "FREQ=HOURLY;BYHOUR=3", "FREQ=DAILY;BYMINUTE="] {
            XCTAssertThrowsError(try RRule(bad), bad)
        }
        XCTAssertEqual((try? RRule("rrule:freq=daily;byhour=4"))?.text, "FREQ=DAILY;BYHOUR=4")
    }

    func testNeverMatchingRuleIsBounded() throws {
        // Feb 30 cannot exist, but this rule is valid: it just must not loop forever. Use a huge interval instead.
        let rule = try RRule("FREQ=WEEKLY;INTERVAL=1000;BYDAY=MO")
        let start = Date()
        _ = rule.occurrences(after: anchor.addingTimeInterval(86400 * 30), anchor: anchor, timeZone: london, limit: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
