import XCTest
@testable import LauncherCore

final class CalendarTimeLayoutTests: XCTestCase {
    private var calendar: Calendar { var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!; return cal }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testOverlappingMeetingsUseSeparateColumnsAndTouchingMeetingsDoNot() {
        let day = date("2026-10-06T00:00:00Z")
        let placements = CalendarTimeLayout.placements([
            .init(id: "a", start: date("2026-10-06T08:00:00Z"), end: date("2026-10-06T09:00:00Z")),
            .init(id: "b", start: date("2026-10-06T08:30:00Z"), end: date("2026-10-06T09:30:00Z")),
            .init(id: "c", start: date("2026-10-06T09:30:00Z"), end: date("2026-10-06T10:30:00Z"))
        ], on: day, calendar: calendar)
        XCTAssertEqual(placements.map(\.columns), [2, 2, 1]); XCTAssertEqual(placements.map(\.column), [0, 1, 0])
        XCTAssertEqual(placements[0].startMinute, 540); XCTAssertEqual(placements[0].endMinute, 600)
    }
    func testOvernightEventsClipAtMidnightAndExclusiveEndDoesNotRepeat() {
        let event = CalendarTimeLayout.Item(id: "overnight", start: date("2026-10-05T22:30:00Z"), end: date("2026-10-06T00:00:00Z"))
        let first = CalendarTimeLayout.placements([event], on: date("2026-10-05T12:00:00Z"), calendar: calendar)
        let second = CalendarTimeLayout.placements([event], on: date("2026-10-06T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(first.first?.startMinute, 1410); XCTAssertEqual(first.first?.endMinute, 1440)
        XCTAssertEqual(second.first?.startMinute, 0); XCTAssertEqual(second.first?.endMinute, 60)
        let midnight = CalendarTimeLayout.Item(id: "midnight", start: date("2026-10-05T20:00:00Z"), end: date("2026-10-05T23:00:00Z"))
        XCTAssertTrue(CalendarTimeLayout.placements([midnight], on: date("2026-10-06T12:00:00Z"), calendar: calendar).isEmpty)
    }
    func testDSTDaysStillPlaceNineAMOnNineAMLine() {
        for (day, nine) in [("2026-03-29T00:00:00Z", "2026-03-29T08:00:00Z"), ("2026-10-25T00:00:00Z", "2026-10-25T09:00:00Z")] {
            XCTAssertEqual(CalendarTimeLayout.minute(date(nine), on: date(day), calendar: calendar), 540)
        }
    }
    func testShortMeetingsHaveClickableHeightAndStableOrdering() {
        let start = date("2026-10-06T08:00:00Z")
        let items = [CalendarTimeLayout.Item(id: "b", start: start, end: start.addingTimeInterval(60)), .init(id: "a", start: start, end: start.addingTimeInterval(60))]
        let placements = CalendarTimeLayout.placements(items, on: start, calendar: calendar)
        XCTAssertEqual(placements.map(\.id), ["a", "b"])
        XCTAssertEqual(placements.first!.endMinute - placements.first!.startMinute, 25)
    }
    func testLateMeetingKeepsItsTrueStartLine() {
        let start = date("2026-10-06T22:59:00Z")
        let placement = CalendarTimeLayout.placements([.init(id: "late", start: start, end: start.addingTimeInterval(60))], on: start, calendar: calendar).first!
        XCTAssertEqual(placement.startMinute, 1439)
        XCTAssertEqual(placement.endMinute - placement.startMinute, 25)
    }
}
