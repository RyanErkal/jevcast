import XCTest
@testable import LauncherCore

final class AutomationAlertTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func run(_ state: RunState, finished: Date, alerted: Bool = false) -> RunRecord {
        let a = Automation(id: "a-1", name: "Desktop tidy", kind: .script(ScriptTask(executable: "/bin/echo", workingDirectory: "/tmp")),
                           schedule: Schedule(rule: .manual))
        var r = RunRecord(id: "20260926T080000Z-abcd", automation: a, trigger: .manual, occurrence: nil, queued: finished)
        r.state = state; r.finished = finished; r.alerted = alerted; r.summary = "Moved 3 files"
        return r
    }

    func testQuietHoursAcrossMidnight() {
        let q = QuietHours(start: 22 * 60, end: 7 * 60)
        XCTAssertTrue(q.contains(date(26, 23), calendar: calendar))
        XCTAssertTrue(q.contains(date(27, 6, 59), calendar: calendar))
        XCTAssertFalse(q.contains(date(27, 7), calendar: calendar))
        XCTAssertFalse(q.contains(date(26, 12), calendar: calendar))
        XCTAssertEqual(q.end(after: date(26, 23), calendar: calendar), date(27, 7))
        XCTAssertEqual(q.end(after: date(27, 3), calendar: calendar), date(27, 7))
        XCTAssertNil(q.end(after: date(26, 12), calendar: calendar))
    }

    func testQuietHoursSameDayAndEmpty() {
        let q = QuietHours(start: 12 * 60, end: 13 * 60 + 30)
        XCTAssertTrue(q.contains(date(26, 12, 10), calendar: calendar))
        XCTAssertEqual(q.end(after: date(26, 12, 10), calendar: calendar), date(26, 13, 30))
        XCTAssertFalse(QuietHours(start: 600, end: 600).contains(date(26, 10), calendar: calendar))
    }

    func testDecisions() {
        let now = date(26, 12)
        let on = AlertSettings()
        XCTAssertEqual(AlertDecision.decide(run(.needsApproval, finished: now), policy: Policy(), settings: on, now: now, calendar: calendar), .show)
        XCTAssertEqual(AlertDecision.decide(run(.needsApproval, finished: now, alerted: true), policy: Policy(), settings: on, now: now, calendar: calendar), .skip)
        XCTAssertEqual(AlertDecision.decide(run(.succeeded, finished: now), policy: Policy(), settings: on, now: now, calendar: calendar), .skip)
        XCTAssertEqual(AlertDecision.decide(run(.succeeded, finished: now), policy: Policy(alertOnSuccess: true), settings: on, now: now, calendar: calendar), .skip)
        XCTAssertEqual(AlertDecision.decide(run(.failed, finished: now), policy: Policy(alertOnFailure: false), settings: on, now: now, calendar: calendar), .skip)
        XCTAssertEqual(AlertDecision.decide(run(.failed, finished: now), policy: Policy(), settings: AlertSettings(failures: false), now: now, calendar: calendar), .skip)
        XCTAssertEqual(AlertDecision.decide(run(.failed, finished: now), policy: Policy(), settings: on, now: now, calendar: calendar), .show)
        XCTAssertEqual(AlertDecision.decide(run(.running, finished: now), policy: Policy(), settings: on, now: now, calendar: calendar), .skip)
        XCTAssertEqual(AlertDecision.decide(run(.needsInput, finished: now), policy: Policy(), settings: AlertSettings(enabled: false), now: now, calendar: calendar), .skip)
        // Old history never replays.
        XCTAssertEqual(AlertDecision.decide(run(.needsInput, finished: date(24, 12)), policy: Policy(), settings: on, now: now, calendar: calendar), .skip)
        let quiet = AlertSettings(quietHours: QuietHours(start: 11 * 60, end: 13 * 60))
        XCTAssertEqual(AlertDecision.decide(run(.needsInput, finished: now), policy: Policy(), settings: quiet, now: now, calendar: calendar), .wait(until: date(26, 13)))
    }

    func testAlertTextHidesNames() {
        let r = run(.needsApproval, finished: Date())
        XCTAssertEqual(AlertText.make(r, name: "Desktop tidy", hideNames: false), AlertText(title: "Desktop tidy", message: "Moved 3 files"))
        let hidden = AlertText.make(r, name: "Desktop tidy", hideNames: true)
        XCTAssertEqual(hidden.title, "An automation")
        XCTAssertFalse(hidden.message.contains("Moved"))
    }

    func testToolCandidatesOrder() {
        let list = ToolLocator.candidates(name: "codex", saved: "/x/codex", home: "/Users/r", nvmVersions: ["v20.11.1", "v22.3.0", "v9.0.0"])
        XCTAssertEqual(list, ["/x/codex", "/Users/r/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                              "/Users/r/.nvm/versions/node/v22.3.0/bin/codex", "/Users/r/.nvm/versions/node/v20.11.1/bin/codex",
                              "/Users/r/.nvm/versions/node/v9.0.0/bin/codex", "/Users/r/.bun/bin/codex"])
        XCTAssertEqual(ToolLocator.versionLine("codex-cli 0.50.0\nmore"), "codex-cli 0.50.0")
        XCTAssertNil(ToolLocator.versionLine("  \n"))
    }

    func testJournalSummary() {
        var j = ApplyJournal(digest: "d", approvedItems: [])
        for (op, status) in [(ProposalItem.Operation.move, ApplyJournal.Entry.Status.done), (.move, .done), (.trash, .done), (.move, .skipped)] {
            j.entries.append(.init(itemID: UUID().uuidString, op: op, source: "/a", destination: nil, status: status))
        }
        XCTAssertEqual(j.summaryText, "Moved 2, trashed 1, skipped 1")
        XCTAssertEqual(ApplyJournal(digest: "d", approvedItems: []).summaryText, "Nothing changed")
    }
}
