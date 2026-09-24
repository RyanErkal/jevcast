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
        XCTAssertEqual(detail, "6:00 PM EDT New York → UK · 5h ahead")
    }

    func testDaylightSavingGaps() {
        XCTAssertEqual(title("6pm atlanta in uk", at: march), "10:00 PM GMT")
        XCTAssertEqual(title("12pm london in dublin", at: ISO8601DateFormatter().date(from: "2026-01-10T12:00:00Z")!), "12:00 PM GMT")
    }

    func testForms() {
        XCTAssertEqual(title("18:00 new york to tokyo"), "07:00 JST (next day)")
        XCTAssertEqual(title("9am in sydney"), "6:00 PM AEST")
        XCTAssertEqual(title("what's 6:30 pm est in india?"), "4:00 AM IST (next day)")
        XCTAssertEqual(title("noon pst in uk"), "8:00 PM BST")
        XCTAssertEqual(title("1am tokyo to la"), "9:00 AM PDT (previous day)")
        XCTAssertEqual(title("now in tokyo"), "9:00 PM JST")
        XCTAssertEqual(title("what time is it in new york"), "8:00 AM EDT")
        XCTAssertEqual(title("atlanta 6pm in uk"), "11:00 PM BST")
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
        for choice in TimeZonePlaces.choices {
            XCTAssertNotNil(TimeZonePlaces.place(forChoice: choice.id)?.timeZone, choice.id)
        }
        XCTAssertNil(TimeZonePlaces.place(forChoice: "zone:Mars/Olympus|Mars"))
        XCTAssertEqual(TimeZonePlaces.label(TimeZone(identifier: "Asia/Kolkata")!, at: september), "IST")
        XCTAssertEqual(TimeZonePlaces.label(TimeZone(identifier: "Asia/Kathmandu")!, at: september), "GMT+5:45")
    }
}
