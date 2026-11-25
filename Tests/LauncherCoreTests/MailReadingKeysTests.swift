import XCTest
@testable import LauncherCore

/// Space and ⇧Space in an open message, and Snooze's one-click times.
final class MailReadingKeysTests: XCTestCase {
    func testSpacePagesDownThenGoesToTheNextMessage() {
        // A 300-point view on a 1000-point message: pages of 260 points keep 40 in view.
        XCTAssertEqual(MailPageScroll.step(offset: 0, viewport: 300, content: 1000, down: true), .scroll(to: 260))
        XCTAssertEqual(MailPageScroll.step(offset: 520, viewport: 300, content: 1000, down: true), .scroll(to: 700),
                       "The last page stops at the end, not past it")
        XCTAssertEqual(MailPageScroll.step(offset: 700, viewport: 300, content: 1000, down: true), .next)
        XCTAssertEqual(MailPageScroll.step(offset: 699, viewport: 300, content: 1000, down: true), .next, "Rounding near the end counts as the end")
        XCTAssertEqual(MailPageScroll.step(offset: 0, viewport: 300, content: 200, down: true), .next, "A short message goes on at once")
    }

    func testShiftSpacePagesUpAndStopsAtTheTop() {
        XCTAssertEqual(MailPageScroll.step(offset: 700, viewport: 300, content: 1000, down: false), .scroll(to: 440))
        XCTAssertEqual(MailPageScroll.step(offset: 100, viewport: 300, content: 1000, down: false), .scroll(to: 0))
        XCTAssertEqual(MailPageScroll.step(offset: 0, viewport: 300, content: 1000, down: false), .stay)
    }

    func testATinyViewStillMovesHalfAPage() {
        XCTAssertEqual(MailPageScroll.step(offset: 0, viewport: 60, content: 1000, down: true), .scroll(to: 30))
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        // November 2026: the 25th is a Wednesday, the 30th a Monday.
        calendar().date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func testSnoozePresetsOnAWeekdayMorning() {
        let presets = MailSnoozePreset.presets(now: date(25, 9, 20), calendar: calendar())
        XCTAssertEqual(presets.map(\.title), ["Later today", "Tomorrow morning", "Next week"])
        XCTAssertEqual(presets.map(\.date), [date(25, 13), date(26, 8), date(30, 8)])
    }

    func testLaterTodayIsLeftOutLateInTheEvening() {
        let presets = MailSnoozePreset.presets(now: date(25, 21, 30), calendar: calendar())
        XCTAssertEqual(presets.map(\.title), ["Tomorrow morning", "Next week"])
    }

    func testOnTheHourLaterTodayIsExactlyThreeHours() {
        XCTAssertEqual(MailSnoozePreset.presets(now: date(25, 10), calendar: calendar()).first?.date, date(25, 13))
    }

    func testNextWeekIsTheFollowingMonday() {
        XCTAssertEqual(MailSnoozePreset.presets(now: date(30, 7), calendar: calendar()).last?.date, date(7, 8, month: 12),
                       "On a Monday, next week is a week later")
        XCTAssertEqual(MailSnoozePreset.presets(now: date(29, 20), calendar: calendar()).last?.date, date(30, 8), "On a Sunday, it is the next day")
    }
}
