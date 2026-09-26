import XCTest
@testable import LauncherCore

final class SchedulerTests: XCTestCase {
    let anchor = Date(timeIntervalSince1970: 1_790_000_000) // fixed

    func automation(_ rule: Schedule.Rule, catchUp: CatchUp = .skip, enabled: Bool = true) -> Automation {
        Automation(id: "a-1", name: "A", kind: .script(ScriptTask(executable: "/bin/true", workingDirectory: "/tmp")),
                   schedule: Schedule(rule: rule, timeZone: "Europe/London", anchor: anchor),
                   policy: Policy(catchUp: catchUp), enabled: enabled, created: anchor)
    }

    func testHourlyDueWithinGrace() {
        let a = automation(.rrule("FREQ=HOURLY;INTERVAL=4"))
        let occ = anchor.addingTimeInterval(4 * 3600)
        let due = Scheduler.due(a, lastCovered: anchor, now: occ.addingTimeInterval(60))
        XCTAssertEqual(due.runs, [occ]); XCTAssertEqual(due.coveredThrough, occ)
        // Same occurrence never runs twice.
        XCTAssertEqual(Scheduler.due(a, lastCovered: occ, now: occ.addingTimeInterval(90)).runs, [])
    }

    func testSkipConsumesMissedSilently() {
        let a = automation(.rrule("FREQ=HOURLY;INTERVAL=4"))
        let now = anchor.addingTimeInterval(13 * 3600) // missed 4h, 8h, 12h; 12h is an hour old
        let due = Scheduler.due(a, lastCovered: anchor, now: now)
        XCTAssertEqual(due.runs, [])
        XCTAssertEqual(due.coveredThrough, anchor.addingTimeInterval(12 * 3600))
        XCTAssertEqual(due.missed, 3)
    }

    func testRunOnceCoversNewest() {
        let a = automation(.rrule("FREQ=HOURLY;INTERVAL=4"), catchUp: .runOnce)
        let due = Scheduler.due(a, lastCovered: anchor, now: anchor.addingTimeInterval(13 * 3600))
        XCTAssertEqual(due.runs, [anchor.addingTimeInterval(12 * 3600)])
        XCTAssertEqual(due.missed, 2)
    }

    func testLongBacklogIsBounded() {
        let a = automation(.rrule("FREQ=HOURLY"), catchUp: .runOnce)
        let now = anchor.addingTimeInterval(3 * 365 * 86400 + 30)
        let due = Scheduler.due(a, lastCovered: anchor, now: now)
        XCTAssertEqual(due.runs.count, 1)
        XCTAssertEqual(due.runs.first, now.addingTimeInterval(-30))
    }

    func testMillisecondRoundTripDoesNotRepeat() {
        let a = automation(.rrule("FREQ=HOURLY"))
        let occ = anchor.addingTimeInterval(3600.0004567)
        let truncated = Date(timeIntervalSinceReferenceDate: (occ.timeIntervalSinceReferenceDate * 1000).rounded(.down) / 1000)
        XCTAssertEqual(Scheduler.due(a, lastCovered: truncated, now: occ.addingTimeInterval(10)).runs, [])
    }

    func testManualPausedAndOnce() {
        XCTAssertEqual(Scheduler.due(automation(.manual), lastCovered: nil, now: anchor.addingTimeInterval(1e6)).runs, [])
        XCTAssertNil(Scheduler.nextRun(automation(.manual), lastCovered: nil, now: anchor))
        XCTAssertEqual(Scheduler.due(automation(.rrule("FREQ=HOURLY"), enabled: false), lastCovered: nil, now: anchor.addingTimeInterval(3601)).runs, [])
        let when = anchor.addingTimeInterval(600)
        let once = automation(.once(when))
        XCTAssertEqual(Scheduler.nextRun(once, lastCovered: nil, now: anchor), when)
        XCTAssertEqual(Scheduler.due(once, lastCovered: nil, now: anchor).runs, [])
        XCTAssertEqual(Scheduler.due(once, lastCovered: nil, now: when.addingTimeInterval(30)).runs, [when])
        XCTAssertEqual(Scheduler.due(once, lastCovered: when, now: when.addingTimeInterval(30)).runs, [])
        XCTAssertNil(Scheduler.nextRun(once, lastCovered: when, now: when))
    }

    func testNextRun() {
        let a = automation(.rrule("FREQ=HOURLY;INTERVAL=4"))
        XCTAssertEqual(Scheduler.nextRun(a, lastCovered: nil, now: anchor.addingTimeInterval(60)), anchor.addingTimeInterval(4 * 3600))
    }
}
