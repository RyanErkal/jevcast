import XCTest
import LauncherCore
@testable import JevLauncher

/// A finished run never takes over the screen: its outcome is a mark in the pill for a few seconds, then it leaves.
/// Only a run that needs an answer or an approval opens as a card by itself.
@MainActor
final class NotchOutcomeTests: XCTestCase {
    private let automation = Automation(id: "backup", name: "Docs and Agents Hourly Backup",
                                        kind: .script(ScriptTask(executable: "/bin/echo", workingDirectory: "/")),
                                        schedule: Schedule(rule: .manual), policy: Policy(alertOnSuccess: true))

    private func run(_ state: RunState, id: String = "r1", needsReview: Bool = false) -> RunRecord {
        var run = RunRecord(id: id, automation: automation, trigger: .schedule, occurrence: nil)
        run.state = state; run.finished = Date()
        run.summary = needsReview ? RunEngine.needsReviewPrefix + "Git branches diverged" : "Backed up 2 folders"
        return run
    }

    private func outcome(_ state: RunState, id: String = "r1", needsReview: Bool = false) -> NotchAlert {
        AutomationCenter.makeAlert(run(state, id: id, needsReview: needsReview), automation: automation, hideNames: false)
    }

    private func running(id: String = "r1") -> NotchAlert {
        var r = run(.running, id: id); r.finished = nil
        return AutomationCenter.runningAlert(r, automation: automation, hideNames: false)
    }

    func testFinishedRunsRestInThePillAndOnlyAnswersOpenACard() {
        for (alert, kind) in [(outcome(.succeeded), NotchAlert.Kind.success), (outcome(.failed), .failure),
                              (outcome(.interrupted), .failure), (outcome(.failed, needsReview: true), .review)] {
            XCTAssertEqual(alert.kind, kind)
            XCTAssertTrue(alert.minimized, "\(kind)")
            XCTAssertEqual(NotchAlertController.restingMode(for: alert), .pill, "\(kind) never opens by itself")
            XCTAssertEqual(NotchAlertController.openMode(for: alert), .card, "a click opens its card")
        }
        for state in [RunState.needsInput, .needsApproval] {
            let alert = outcome(state)
            XCTAssertFalse(alert.minimized)
            XCTAssertEqual(NotchAlertController.restingMode(for: alert), .card, "\(state) needs the user")
        }
    }

    func testTheOutcomeNamesTheAutomation() {
        XCTAssertEqual(running().title, "Docs and Agents Hourly Backup")
        XCTAssertEqual(outcome(.succeeded).title, "Docs and Agents Hourly Backup")
        let fresh = UserDefaults(suiteName: "NotchOutcomeTests.\(UUID().uuidString)")!
        XCTAssertFalse(Preferences(defaults: fresh).automationHideNames, "names show unless hidden in Settings")
    }

    func testOutcomeMarksLeaveByThemselves() throws {
        XCTAssertEqual(NotchTiming.seconds(for: .success, failureSeconds: 8, minimized: true), NotchTiming.doneSeconds)
        XCTAssertEqual(NotchTiming.seconds(for: .failure, failureSeconds: 12, minimized: true), 12)
        XCTAssertEqual(NotchTiming.seconds(for: .review, failureSeconds: 12, minimized: true), 12, "a review in the pill leaves too")
        XCTAssertNil(NotchTiming.seconds(for: .review, failureSeconds: 12), "a review card asked for stays until handled")

        var q = NotchQueue()
        q.add(outcome(.succeeded))
        let shown = try XCTUnwrap(q.presentation)
        let now = Date()
        q.startTimers(now: now, drawn: Set(NotchAlertController.presentedAlerts(shown, mode: .pill).map(\.id)))
        XCTAssertEqual(q.nextDeadline, now.addingTimeInterval(NotchTiming.doneSeconds), "the pill's mark counts down")
        XCTAssertEqual(q.expire(now: now.addingTimeInterval(NotchTiming.doneSeconds)).map(\.id), [shown.id])
        XCTAssertNil(q.presentation, "then the pill leaves")
    }

    func testTheRingTurnsIntoTheMarkInPlace() throws {
        var q = NotchQueue()
        let ring = running()
        q.add(ring)
        XCTAssertEqual(NotchAlertController.restingMode(for: try XCTUnwrap(q.presentation)), .pill)
        let done = outcome(.succeeded)
        q.add(done)
        XCTAssertEqual(q.entries.map(\.alert.id), [done.id], "the outcome replaces its run's ring")
        XCTAssertEqual(NotchAlertController.nextMode(previous: ring, previousMode: .pill, next: done, replyTarget: nil), .pill)
        XCTAssertEqual(NotchIsland.contentKey(alert: ring, mode: .compact, replyTarget: nil),
                       NotchIsland.contentKey(alert: done, mode: .compact, replyTarget: nil),
                       "the pill keeps its identity, so only the mark changes")
        XCTAssertEqual(NotchAlertController.nextMode(previous: ring, previousMode: .detail, next: done, replyTarget: nil), .card,
                       "a running card the user opened shows the outcome as a card")
        XCTAssertEqual(NotchStatus.outcome(.success)?.label, "Done")
        XCTAssertEqual(NotchStatus.outcome(.failure)?.label, "Failed")
        XCTAssertEqual(NotchStatus.outcome(.review)?.label, "Needs review")
        XCTAssertNil(NotchStatus.outcome(.running))
    }

    func testThePillDrawingAnOutcomeCountsAsShown() {
        let done = outcome(.succeeded)
        XCTAssertEqual(NotchAlertController.presentedAlerts(done, mode: .pill).map(\.id), [done.id])
        XCTAssertEqual(NotchAlertController.presentedAlerts(running(), mode: .pill), [], "a ring is not an alert")
        var card = done; card.minimized = false
        XCTAssertEqual(NotchAlertController.presentedAlerts(card, mode: .pill), [], "a card's words are not in the pill")
    }

    func testFinishedRunsTogetherStayOnePill() {
        let a = outcome(.succeeded, id: "r1"), b = outcome(.succeeded, id: "r2")
        let stack = NotchQueue.stack([a, b])
        XCTAssertTrue(stack.minimized)
        XCTAssertEqual(stack.title, "2 automations done")
        XCTAssertEqual(NotchAlertController.restingMode(for: stack), .pill)
        XCTAssertEqual(NotchAlertController.openMode(for: stack), .detail, "a click opens their list")
        XCTAssertEqual(Set(NotchAlertController.presentedAlerts(stack, mode: .pill).map(\.id)), [a.id, b.id])
        XCTAssertTrue(stack.presentation.isPillStack)

        let mixed = NotchQueue.stack([outcome(.needsApproval, id: "r3"), a])
        XCTAssertFalse(mixed.minimized)
        XCTAssertEqual(NotchAlertController.restingMode(for: mixed), .card, "an approval still opens")
    }
}
