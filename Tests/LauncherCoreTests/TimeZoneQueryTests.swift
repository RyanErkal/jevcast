import XCTest
@testable import LauncherCore

final class TimeZoneQueryTests: XCTestCase {
    private let september = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
    // US clocks moved on 8 March 2026, UK clocks on 29 March: the gap is one hour smaller.
    private let march = ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z")!
    private let london = TimeZone(identifier: "Europe/London")!

    private func title(_ text: String, at now: Date? = nil) -> String? {
        TimeZoneQuery.evaluate(text, now: now ?? september, local: london)?.title
    }

    func testRequestedExamples() {
        XCTAssertEqual(title("6pm atlanta time in uk time"), "11:00 PM BST")
        XCTAssertEqual(title("3pm california time in ireland time"), "11:00 PM IST")
        XCTAssertEqual(title("3pm uk time in PST"), "7:00 AM PDT")
        let detail = TimeZoneQuery.evaluate("6pm atlanta time in uk time", now: september, local: london)?.detail
        XCTAssertEqual(detail, "6:00 PM EDT Atlanta → UK · 5h ahead")
    }

    func testDaylightSavingGaps() {
        XCTAssertEqual(title("6pm atlanta in uk", at: march), "10:00 PM GMT")
        XCTAssertEqual(title("12pm london in dublin", at: ISO8601DateFormatter().date(from: "2026-01-10T12:00:00Z")!), "12:00 PM GMT")
    }

    func testForms() {
        XCTAssertEqual(title("18:00 new york to tokyo"), "07:00 JST")
        XCTAssertEqual(title("9am in sydney"), "6:00 PM AEST")
        XCTAssertEqual(title("what's 6:30 pm est in india?"), "4:00 AM IST")
        XCTAssertEqual(title("noon pst in uk"), "8:00 PM BST")
        XCTAssertEqual(title("1am tokyo to la"), "9:00 AM PDT")
        XCTAssertEqual(title("now in tokyo"), "9:00 PM JST")
        XCTAssertEqual(title("what time is it in new york"), "8:00 AM EDT")
        XCTAssertEqual(title("atlanta 6pm in uk"), "11:00 PM BST")
    }

    func testReviewFixes() {
        XCTAssertEqual(title("3pm gmt in new york"), "11:00 AM EDT", "GMT is a fixed zone, not UK local time.")
        XCTAssertEqual(title("3pm uk in utc"), "2:00 PM UTC")
        let ist = TimeZoneQuery.evaluate("noon ist in dublin", now: september, local: london)
        XCTAssertEqual(ist?.title, "7:30 AM IST")
        XCTAssertTrue(ist?.detail.contains("IST read as India Standard Time") ?? false)
        XCTAssertTrue(TimeZoneQuery.evaluate("3pm pst in uk", now: september, local: london)?.detail.contains("PST read as Pacific Time (PDT now)") ?? false)
        XCTAssertTrue(TimeZoneQuery.evaluate("18:00 new york to tokyo", now: september, local: london)?.detail.contains("next day") ?? false)
        for text in ["what time is it now in tokyo", "time now in tokyo", "what's the time now in tokyo", "whats the current time in tokyo", "what\u{2019}s the time in tokyo"] {
            XCTAssertEqual(title(text), "9:00 PM JST", text)
        }
        XCTAssertEqual(title("6.30pm uk in pst"), "10:30 AM PDT")
        XCTAssertEqual(title("3pm pst in my time"), "11:00 PM BST")
        XCTAssertEqual(title("3pm pst for me"), "11:00 PM BST")
        XCTAssertEqual(title("6pm from london to new york"), "1:00 PM EDT")
        XCTAssertEqual(title("time in new york city"), "8:00 AM EDT")
        XCTAssertEqual(title("3pm in london in tokyo"), "11:00 PM JST")
        XCTAssertEqual(title("1pm in kathmandu"), "5:45 PM GMT+5:45")
        for text in ["time to christmas", "time to easter", "now to wake", "time to center", "tomorrow 9am uk in pst", "in 2 hours what time will it be in tokyo"] {
            XCTAssertNil(title(text), text)
        }
        XCTAssertNil(TimeZoneQuery.clock(in: "screen time", explicitOnly: true))
    }

    func testSecondReviewFixes() {
        XCTAssertEqual(title("what's 8pm tonight in new york"), "3:00 PM EDT")
        XCTAssertEqual(title("3pm british time in pst"), "7:00 AM PDT")
        XCTAssertEqual(title("3pm greenwich mean time in pst"), "8:00 AM PDT")
        XCTAssertEqual(title("6pm my time in tokyo"), "2:00 AM JST")
        XCTAssertEqual(TimeZoneQuery.evaluate("noon ist in dublin", now: september, local: london)?.detail.hasPrefix("12:00 PM IST India →"), true)
        XCTAssertEqual(TimeZoneQuery.evaluate("3pm washington dc in uk", now: september, local: london)?.detail.contains("New York →"), true)
        XCTAssertNil(title("6pm in norfolk"))
        XCTAssertTrue(TimeZonePlaces.mentioned(in: "screen time for charlotte").isEmpty)
        XCTAssertEqual(TimeZonePlaces.mentioned(in: "6pm in cork.").first?.place.name, "Cork")
        XCTAssertEqual(TimeZoneQuery.clock(in: "whats the time in cork if its 6pm in georgia", explicitOnly: true)?.hour, 18)
        XCTAssertTrue(TimeZoneQuery.mentionsLocal("when is that for me"))
        XCTAssertFalse(TimeZoneQuery.mentionsLocal("6pm for my mate in cork"))
    }

    func testClockChangeDays() {
        let skipped = TimeZoneQuery.evaluate("1:30am london in new york", now: ISO8601DateFormatter().date(from: "2026-03-29T12:00:00Z")!, local: london)
        XCTAssertTrue(skipped?.detail.contains("time moved forward") ?? false)
        let repeated = TimeZoneQuery.evaluate("1:30am london in new york", now: ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!, local: london)
        XCTAssertTrue(repeated?.detail.contains("happens twice") ?? false)
        // Sydney moves forward on 4 October 2026.
        XCTAssertEqual(title("9am sydney in london", at: ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!), "11:00 PM BST")
    }

    func testNotesForBroadPlaces() {
        let answer = TimeZoneQuery.evaluate("3pm uk in usa", now: september, local: london)
        XCTAssertEqual(answer?.title, "10:00 AM EDT")
        XCTAssertTrue(answer?.detail.contains("US Eastern assumed") ?? false)
    }

    func testNotTimeConversions() {
        XCTAssertNil(title("6 in uk"), "A bare number is not a time.")
        XCTAssertNil(title("12 in in cm"))
        XCTAssertNil(title("6pm in narnia"))
        XCTAssertNil(title("remind me at 3pm to call mum"))
        XCTAssertNil(title("13pm uk in pst"))
        XCTAssertNil(title("25:00 uk in pst"))
    }

    func testClockAnywhere() {
        XCTAssertEqual(TimeZoneQuery.clock(in: "what's 6 pm for my mate in cork"), .init(hour: 18, minute: 0, isNow: false, twentyFourHour: false))
        XCTAssertNil(TimeZoneQuery.clock(in: "open slack"))
    }

    func testChoicesResolve() {
        for choice in TimeZonePlaces.choices(for: "6pm in kathmandu") {
            XCTAssertNotNil(TimeZonePlaces.place(forChoice: choice.id)?.timeZone, choice.id)
        }
        XCTAssertNil(TimeZonePlaces.place(forChoice: "zone:Mars/Olympus|Mars"))
        XCTAssertEqual(TimeZonePlaces.choices(for: "6pm in kathmandu").first?.id, "zone:Asia/Kathmandu|Kathmandu")
        XCTAssertEqual(TimeZonePlaces.label(TimeZone(identifier: "Asia/Kolkata")!, at: september), "IST")
        XCTAssertEqual(TimeZonePlaces.label(TimeZone(identifier: "Asia/Kathmandu")!, at: september), "GMT+5:45")
    }
}
