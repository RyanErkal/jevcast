import XCTest
@testable import LauncherCore

final class CalendarEventDraftTests: XCTestCase {
    private var calendar: Calendar { var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!; return cal }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testANewEventStartsAtTheNextHalfHourOrTheClickedQuarter() {
        let today = CalendarEventDraft.new(on: date(9, 14, 10), now: date(9, 14, 10), calendar: calendar)
        XCTAssertEqual(today.start, date(9, 14, 30)); XCTAssertEqual(today.end, date(9, 15, 30))
        let later = CalendarEventDraft.new(on: date(12, 0), now: date(9, 14, 10), calendar: calendar)
        XCTAssertEqual(later.start, date(12, 9))
        let clicked = CalendarEventDraft.new(on: date(12, 0), minute: 13 * 60 + 52, now: date(9, 14, 10), calendar: calendar)
        XCTAssertEqual(clicked.start, date(12, 13, 45))
        let late = CalendarEventDraft.new(on: date(9, 23, 50), now: date(9, 23, 50), calendar: calendar)
        XCTAssertEqual(late.start, date(9, 23))
    }

    func testProblemsStopASave() {
        var draft = CalendarEventDraft(title: " ", start: date(9, 10), end: date(9, 11))
        XCTAssertEqual(draft.problem, "Add a title.")
        draft.title = "Review"; XCTAssertNil(draft.problem)
        draft.end = date(9, 10); XCTAssertEqual(draft.problem, "The end must be after the start.")
        draft.allDay = true; XCTAssertNil(draft.problem, "A one-day all-day event starts and ends on the same day.")
        draft.end = date(8, 10); XCTAssertNotNil(draft.problem)
    }

    func testAllDayCoversWholeDaysAndAMoveKeepsTheLength() {
        let allDay = CalendarEventDraft(title: "Trip", start: date(9, 15), end: date(10, 9), allDay: true)
        let stored = allDay.storedTimes(calendar: calendar)
        XCTAssertEqual(stored.start, date(9, 0)); XCTAssertEqual(stored.end, date(11, 0))
        let timed = CalendarEventDraft(title: "Call", start: date(9, 10), end: date(9, 10, 45))
        let moved = timed.moved(minutes: -30, days: 2, calendar: calendar)
        XCTAssertEqual(moved.start, date(11, 9, 30)); XCTAssertEqual(moved.end, date(11, 10, 15))
        XCTAssertEqual(allDay.moved(minutes: 45, days: 1, calendar: calendar).start, date(10, 15), "An all-day event moves by days only.")
        XCTAssertEqual(CalendarEventDraft.snappedMinutes(22), 15); XCTAssertEqual(CalendarEventDraft.snappedMinutes(23), 30)
        XCTAssertEqual(CalendarEventDraft.snappedMinutes(-8), -15)
    }

    func testTheFilterReadsEveryFieldAndNeedsEveryWord() {
        let fields = ["Design review", "Room 4", "Work", "Sam Taylor", "Bring the launch checklist"]
        XCTAssertTrue(CalendarEventFilter.matches("", fields: fields))
        XCTAssertTrue(CalendarEventFilter.matches("room", fields: fields))
        XCTAssertTrue(CalendarEventFilter.matches("sam checklist", fields: fields))
        XCTAssertFalse(CalendarEventFilter.matches("sam budget", fields: fields))
    }

    func testAMeetingIsAnnouncedOnceShortlyBeforeItStarts() {
        let now = date(9, 10)
        let events = [MeetingAlert.Candidate(id: "soon", start: date(9, 10, 4), allDay: false),
                      MeetingAlert.Candidate(id: "later", start: date(9, 10, 20), allDay: false),
                      MeetingAlert.Candidate(id: "day", start: date(9, 10, 1), allDay: true),
                      MeetingAlert.Candidate(id: "started", start: now.addingTimeInterval(-30), allDay: false),
                      MeetingAlert.Candidate(id: "old", start: date(9, 9, 50), allDay: false)]
        let due = MeetingAlert.due(events, now: now, announced: [])
        XCTAssertEqual(due.map(\.id), ["started", "soon"])
        XCTAssertEqual(MeetingAlert.due(events, now: now, announced: Set(due.map(\.key))), [])
        // A moved meeting has a new start, so it is announced again.
        let moved = [MeetingAlert.Candidate(id: "soon", start: date(9, 10, 3), allDay: false)]
        XCTAssertEqual(MeetingAlert.due(moved, now: now, announced: Set(due.map(\.key))).count, 1)
        XCTAssertEqual(MeetingAlert.when(date(9, 10, 4), now: now), "Starts in 4 min")
        XCTAssertEqual(MeetingAlert.when(now.addingTimeInterval(-30), now: now), "Starts now")
    }
}
