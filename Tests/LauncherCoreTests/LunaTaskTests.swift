import XCTest
@testable import LauncherCore

final class LunaTaskTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c }()
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testParsesSchedulesAtEitherEnd() throws {
        let a = try XCTUnwrap(LunaTaskQuery.parse("every weekday at 8am brief me on my meetings and unread email"))
        XCTAssertEqual(a.schedule, .daily(hour: 8, minute: 0, weekdays: [2, 3, 4, 5, 6]))
        XCTAssertEqual(a.prompt, "brief me on my meetings and unread email")
        XCTAssertEqual(a.contexts, [.calendar, .unreadMail])
        let b = try XCTUnwrap(LunaTaskQuery.parse("summarise my reminders every evening at 7"))
        XCTAssertEqual(b.schedule, .daily(hour: 19, minute: 0, weekdays: []))
        XCTAssertEqual(b.contexts, [.reminders])
        let c = try XCTUnwrap(LunaTaskQuery.parse("every monday at 9:30 plan my week"))
        XCTAssertEqual(c.schedule, .daily(hour: 9, minute: 30, weekdays: [2]))
        XCTAssertEqual(c.schedule.summary, "Every Monday at 09:30")
        let d = try XCTUnwrap(LunaTaskQuery.parse("every 2 hours check my unread mail"))
        XCTAssertEqual(d.schedule, .everyHours(2))
        XCTAssertEqual(try XCTUnwrap(LunaTaskQuery.parse("daily at 6pm write a short journal prompt")).schedule, .daily(hour: 18, minute: 0, weekdays: []))
        XCTAssertNil(LunaTaskQuery.parse("every day"))
        XCTAssertNil(LunaTaskQuery.parse("safari"))
        XCTAssertNil(LunaTaskQuery.parse("remind me to call mum at 5pm"))
    }

    func testNextRunAndDue() {
        let created = date("2026-09-24T06:00:00Z")
        var task = LunaTask(name: "Brief", prompt: "brief me", schedule: .daily(hour: 8, minute: 0, weekdays: []), contexts: [], created: created)
        // 08:00 London is 07:00 UTC in September.
        XCTAssertEqual(task.schedule.nextRun(after: created, anchor: created, calendar: cal), date("2026-09-24T07:00:00Z"))
        XCTAssertNil(task.due(at: date("2026-09-24T06:59:00Z"), calendar: cal))
        XCTAssertEqual(task.due(at: date("2026-09-24T07:00:30Z"), calendar: cal)?.late, false)
        XCTAssertEqual(task.due(at: date("2026-09-24T12:00:00Z"), calendar: cal)?.late, true, "Missed by more than three hours: skipped.")
        task.lastRun = date("2026-09-24T07:00:30Z")
        XCTAssertNil(task.due(at: date("2026-09-24T09:00:00Z"), calendar: cal), "Runs once per day.")
        let hourly = LunaTask(name: "h", prompt: "x y", schedule: .everyHours(2), contexts: [], created: created)
        XCTAssertEqual(hourly.nextRun(after: date("2026-09-24T07:30:00Z"), calendar: cal), date("2026-09-24T08:00:00Z"))
        task.enabled = false
        XCTAssertNil(task.due(at: date("2026-09-25T07:00:30Z"), calendar: cal))
    }

    func testTaskRequestCarriesTaggedData() {
        let task = LunaTask(name: "Brief", prompt: "brief me", schedule: .everyHours(1), contexts: [.calendar])
        let request = LunaRequest.task(task, sections: [("Calendar", "- 09:00 Standup")], sent: [.calendar])
        XCTAssertEqual(request.sent, [.typedText, .calendar])
        XCTAssertTrue(request.user.contains("<calendar>\n- 09:00 Standup\n</calendar>"))
        XCTAssertEqual(LunaTaskContext.unreadMail.lunaContext, .mailMessage)
    }
}
