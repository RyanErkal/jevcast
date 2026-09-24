import XCTest
@testable import LauncherCore

final class CreateQueryTests: XCTestCase {
    func testReminderWithTime() throws {
        let query = try XCTUnwrap(CreateQuery.parse("remind me to call mum tomorrow at 5pm"))
        XCTAssertEqual(query.kind, .reminder)
        XCTAssertEqual(query.title, "Call mum")
        XCTAssertTrue(query.hasTime)
        let date = try XCTUnwrap(query.date)
        XCTAssertTrue(Calendar.current.isDateInTomorrow(date))
        XCTAssertEqual(Calendar.current.component(.hour, from: date), 17)
    }

    func testReminderWithoutDate() throws {
        let query = try XCTUnwrap(CreateQuery.parse("remind me to buy milk"))
        XCTAssertEqual(query.title, "Buy milk")
        XCTAssertNil(query.date)
        XCTAssertFalse(query.hasTime)
    }

    func testReminderDayOnly() throws {
        let query = try XCTUnwrap(CreateQuery.parse("remind me to renew passport tomorrow"))
        XCTAssertEqual(query.title, "Renew passport")
        XCTAssertFalse(query.hasTime)
        XCTAssertTrue(Calendar.current.isDateInTomorrow(try XCTUnwrap(query.date)))
    }

    func testEventNeedsADate() throws {
        XCTAssertNil(CreateQuery.parse("schedule backups"), "Without a date this stays a normal search.")
        let query = try XCTUnwrap(CreateQuery.parse("add event lunch with Sam tomorrow at 1pm"))
        XCTAssertEqual(query.kind, .event)
        XCTAssertEqual(query.title, "Lunch with Sam")
        XCTAssertEqual(Calendar.current.component(.hour, from: try XCTUnwrap(query.date)), 13)
    }

    func testOtherTextIsNotACreateQuery() {
        XCTAssertNil(CreateQuery.parse("reminders"))
        XCTAssertNil(CreateQuery.parse("remind me"))
        XCTAssertNil(CreateQuery.parse("safari"))
    }

    func testMeetingLinks() {
        XCTAssertEqual(MeetingLink.find(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/123?pwd=x thanks"])?.host, "us02web.zoom.us")
        XCTAssertEqual(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertNil(MeetingLink.find(in: ["https://example.com/agenda"]))
    }
}

final class CreateQueryEdgeTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }

    func testBareReminderPrefixNeedsADate() {
        XCTAssertNil(CreateQuery.parse("reminder app"))
        XCTAssertNil(CreateQuery.parse("remind me later"))
        XCTAssertNotNil(CreateQuery.parse("remind me to stretch"))
    }

    func testRelativeTimes() throws {
        let now = Date()
        let twenty = try XCTUnwrap(CreateQuery.parse("remind me to call in 20 minutes", now: now))
        XCTAssertEqual(twenty.title, "Call")
        XCTAssertTrue(twenty.hasTime)
        XCTAssertEqual(try XCTUnwrap(twenty.date).timeIntervalSince(now), 1200, accuracy: 1)
        for (text, seconds) in [("in an hour", 3600.0), ("in half an hour", 1800), ("in 2h", 7200), ("in 5 min", 300)] {
            let date = try XCTUnwrap(CreateQuery.parse("remind me to stretch " + text, now: now)?.date, text)
            XCTAssertEqual(date.timeIntervalSince(now), seconds, accuracy: 1, text)
        }
        let months = CreateQuery.parse("remind me to plan in 2 months", now: now)?.date
        XCTAssertFalse(months.map { $0.timeIntervalSince(now) < 86_400 } ?? false, "Months are not minutes.")
    }

    func testAtHourWithoutMeridiem() throws {
        let query = try XCTUnwrap(CreateQuery.parse("remind me to take pills at 9"))
        XCTAssertEqual(query.title, "Take pills")
        let date = try XCTUnwrap(query.date)
        XCTAssertTrue([9, 21].contains(calendar.component(.hour, from: date)))
        XCTAssertGreaterThan(date, Date())
    }

    func testMealWordsStayInTheTitle() throws {
        let lunch = try XCTUnwrap(CreateQuery.parse("add event lunch with Sam tomorrow at 1pm"))
        XCTAssertEqual(lunch.title, "Lunch with Sam")
        let dinner = try XCTUnwrap(CreateQuery.parse("add event dinner tomorrow 7pm"))
        XCTAssertEqual(dinner.title, "Dinner")
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(dinner.date)), 19)
        XCTAssertEqual(try XCTUnwrap(CreateQuery.parse("remind me to take lunch today")).title, "Take lunch")
    }

    func testPastMonthDayMovesToNextYear() throws {
        let date = try XCTUnwrap(CreateQuery.parse("remind me to renew on jan 3")?.date)
        XCTAssertGreaterThan(date, Date())
        XCTAssertEqual(calendar.component(.month, from: date), 1)
    }

    func testSpoofedMeetingLinksAreIgnored() {
        XCTAssertNil(MeetingLink.find(in: ["https://evil.example/zoom.us/j/1"]))
        XCTAssertNil(MeetingLink.find(in: ["https://evil.example/?u=meet.google.com/abc"]))
        XCTAssertNotNil(MeetingLink.find(in: ["https://acme.zoom.us/j/99"]))
    }
}
