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
        let query = try XCTUnwrap(CreateQuery.parse("remind me buy milk"))
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
