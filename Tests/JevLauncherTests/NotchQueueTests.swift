import XCTest
import LauncherCore
@testable import JevLauncher

final class NotchQueueTests: XCTestCase {
    private func alert(_ id: String, _ kind: NotchAlert.Kind, run: String? = nil) -> NotchAlert {
        NotchAlert(id: id, kind: kind, symbol: "bell", title: id, message: "m", runID: run)
    }

    func testPriorityPutsQuestionsFirstAndHidesRunning() {
        var q = NotchQueue()
        q.add(alert("r", .running)); q.add(alert("f", .failure)); q.add(alert("a", .approval)); q.add(alert("i", .info))
        XCTAssertEqual(q.visible.map(\.alert.id), ["a", "f", "i"])
        let shown = try? XCTUnwrap(q.presentation)
        XCTAssertEqual(shown?.id, NotchQueue.stackID)
        XCTAssertEqual(shown?.stackCount, 3)
        XCTAssertEqual(shown?.title, "3 automations need you")
        XCTAssertEqual(shown?.kind, .approval)
    }

    func testSingleAlertIsNotAStackAndRunningShowsWhenAlone() {
        var q = NotchQueue()
        q.add(alert("r", .running))
        XCTAssertEqual(q.presentation?.id, "r")
        XCTAssertFalse(q.presentation?.isStack ?? true)
        q.add(alert("f", .failure))
        XCTAssertEqual(q.presentation?.id, "f")
        q.remove("f")
        XCTAssertEqual(q.presentation?.id, "r")
        q.add(alert("r2", .running))
        XCTAssertEqual(q.presentation?.title, "2 automations running")
    }

    func testFailuresOnlyStackTitle() {
        var q = NotchQueue()
        q.add(alert("f1", .failure)); q.add(alert("f2", .failure))
        XCTAssertEqual(q.presentation?.title, "2 automations failed")
        XCTAssertEqual(q.presentation?.stack.map(\.id), ["f1", "f2"])
    }

    func testDedupeByIDAndRun() {
        var q = NotchQueue()
        XCTAssertTrue(q.add(alert("x", .failure)))
        XCTAssertFalse(q.add(alert("x", .failure)), "The same alert twice changes nothing")
        q.add(alert("running:a/1", .running, run: "1"))
        q.add(alert("run:a/1", .failure, run: "1"))
        XCTAssertEqual(q.entries.filter { $0.alert.runID == "1" }.map(\.alert.id), ["run:a/1"], "A newer alert for the run replaces the older one")
        XCTAssertEqual(q.entries.count, 2)
    }

    func testTimingPerKind() {
        XCTAssertNil(NotchTiming.seconds(for: .running, failureSeconds: 8))
        XCTAssertNil(NotchTiming.seconds(for: .question, failureSeconds: 8))
        XCTAssertNil(NotchTiming.seconds(for: .approval, failureSeconds: 8))
        XCTAssertEqual(NotchTiming.seconds(for: .failure, failureSeconds: 8), 8)
        XCTAssertEqual(NotchTiming.seconds(for: .success, failureSeconds: 8), 10)
        XCTAssertEqual(NotchTiming.seconds(for: .info, failureSeconds: 8), 6)
    }

    func testTimedAlertsExpireOnlyWhileVisibleAndNotPaused() {
        let now = Date()
        var q = NotchQueue()
        q.failureSeconds = 8
        q.add(alert("q", .question)); q.add(alert("f", .failure)); q.add(alert("r", .running))
        // The open list draws both rows.
        let drawn: Set<String> = ["q", "f"]
        q.startTimers(now: now, drawn: drawn)
        XCTAssertNil(q.entries.first { $0.alert.id == "q" }?.deadline, "Questions persist")
        XCTAssertNil(q.entries.first { $0.alert.id == "r" }?.deadline, "Running persists")
        XCTAssertEqual(q.nextDeadline, now.addingTimeInterval(8))
        XCTAssertTrue(q.expire(now: now.addingTimeInterval(7)).isEmpty)
        // Hover pauses; the countdown starts again in full.
        q.pauseTimers()
        XCTAssertNil(q.nextDeadline)
        q.startTimers(now: now.addingTimeInterval(7), drawn: drawn)
        XCTAssertTrue(q.expire(now: now.addingTimeInterval(9)).isEmpty)
        XCTAssertEqual(q.expire(now: now.addingTimeInterval(15)).map(\.id), ["f"])
        XCTAssertEqual(q.presentation?.id, "q")
    }

    func testInfoExpiresThenRunningReturns() {
        let now = Date()
        var q = NotchQueue()
        q.add(alert("r", .running))
        q.add(NotchAlert(id: "i", kind: .info, symbol: "bell", title: "i", message: "m"))
        q.startTimers(now: now, drawn: ["i"])
        XCTAssertNotNil(q.entries.first { $0.alert.id == "i" }?.deadline)
        XCTAssertEqual(q.expire(now: now.addingTimeInterval(7)).map(\.id), ["i"])
        XCTAssertEqual(q.presentation?.id, "r")
    }

    @MainActor func testModesFollowTheAlert() {
        let running = alert("r", .running)
        var question = alert("q", .question)
        question.allowsReply = true
        XCTAssertEqual(NotchAlertController.restingMode(for: running), .pill)
        XCTAssertEqual(NotchAlertController.restingMode(for: question), .card)
        XCTAssertEqual(NotchAlertController.nextMode(previous: nil, previousMode: .card, next: running, replyTarget: nil), .pill)
        XCTAssertEqual(NotchAlertController.nextMode(previous: running, previousMode: .detail, next: running, replyTarget: nil), .detail)
        XCTAssertEqual(NotchAlertController.nextMode(previous: running, previousMode: .detail, next: question, replyTarget: nil), .card)
        let stack = NotchQueue.stack([question, alert("f", .failure)])
        let grown = NotchQueue.stack([question, alert("f", .failure), alert("a", .approval)])
        XCTAssertEqual(NotchAlertController.nextMode(previous: stack, previousMode: .detail, next: grown, replyTarget: nil), .detail)
        XCTAssertEqual(NotchAlertController.nextMode(previous: stack, previousMode: .reply, next: grown, replyTarget: "q"), .reply)
        XCTAssertEqual(NotchAlertController.nextMode(previous: stack, previousMode: .reply, next: grown, replyTarget: "gone"), .card)
    }

    @MainActor func testReplyEndsWhenTargetChangesOrDisallowsReply() {
        var question = alert("q", .question)
        question.allowsReply = true
        var changed = question
        changed.message = "A new question"
        XCTAssertEqual(NotchAlertController.nextMode(previous: question, previousMode: .reply, next: changed, replyTarget: "q"), .card)
        changed = question
        changed.allowsReply = false
        XCTAssertEqual(NotchAlertController.nextMode(previous: question, previousMode: .reply, next: changed, replyTarget: "q"), .card)
        XCTAssertNil(NotchAlertController.replyAlert(in: changed, target: "q"))
        XCTAssertNil(NotchAlertController.replyAlert(in: question, target: "missing"))
    }

    @MainActor func testInterruptedCloseReexpandsAndReplyExitClearsEditing() {
        let state = NotchState()
        let question = alert("q", .question)
        state.present(question, mode: .reply)
        state.replyTarget = question.id
        var replies: [String] = []
        state.performHandler = { _, action in replies.append(action) }
        state.submitReply("answer")
        XCTAssertEqual(replies.count, 1)
        state.endReply()
        state.submitReply("late answer")
        XCTAssertEqual(replies.count, 1, "A removed reply field cannot submit to the next alert")
        XCTAssertNil(state.replyTarget)
        XCTAssertEqual(state.mode, .card)
        state.expanded = false
        state.present(question, mode: .card)
        XCTAssertTrue(state.expanded, "A new arrival cancels the collapsed state even while the panel remains visible")
    }

    @MainActor func testPointerInputClosesAndCanReopenWithoutRecreatingPanel() {
        XCTAssertFalse(NotchAlertController.acceptsPointer(expanded: false, visible: true, ready: true, inside: true))
        XCTAssertFalse(NotchAlertController.acceptsPointer(expanded: true, visible: false, ready: true, inside: true))
        XCTAssertFalse(NotchAlertController.acceptsPointer(expanded: true, visible: true, ready: false, inside: true))
        XCTAssertFalse(NotchAlertController.acceptsPointer(expanded: true, visible: true, ready: true, inside: false))
        XCTAssertTrue(NotchAlertController.acceptsPointer(expanded: true, visible: true, ready: true, inside: true))
    }

    func testTransparentMarginsAndCornersDoNotAcceptPointer() {
        let a = alert("a", .approval)
        for notch in [false, true] {
            let g = NotchGeometry(screenFrame: CGRect(x: 100, y: 200, width: 1512, height: 982),
                                  notchWidth: notch ? 180 : 0, notchHeight: notch ? 32 : 0)
            for mode: NotchState.Mode in [.pill, .card, .detail, .reply] {
                let frame = g.panelFrame(mode, alert: a)
                let size = g.shapeSize(mode, alert: a)
                let bottom = frame.maxY - (notch ? 0 : NotchGeometry.topGap) - size.height
                XCTAssertFalse(g.contains(CGPoint(x: frame.minX + 1, y: frame.midY), mode: mode, alert: a))
                XCTAssertFalse(g.contains(CGPoint(x: frame.midX, y: frame.minY + 1), mode: mode, alert: a))
                XCTAssertFalse(g.contains(CGPoint(x: frame.midX - size.width / 2 + 1, y: bottom + 1), mode: mode, alert: a))
                XCTAssertTrue(g.contains(CGPoint(x: frame.midX, y: bottom + size.height / 2), mode: mode, alert: a))
                if !notch { XCTAssertFalse(g.contains(CGPoint(x: frame.midX, y: frame.maxY - 1), mode: mode, alert: a)) }
            }
        }
    }

    func testRunDedupeIsScopedToAutomationAndRecallKeepsLiveAlert() {
        var q = NotchQueue()
        var a = alert("a", .question, run: "same")
        a.automationID = "one"
        var b = alert("b", .question, run: "same")
        b.automationID = "two"
        q.add(a); q.add(b)
        XCTAssertEqual(q.entries.count, 2)
        XCTAssertTrue(q.containsRunOrID(a))
        XCTAssertTrue(q.containsRunOrID(NotchAlert(id: "result", kind: .success, symbol: "checkmark", title: "done", message: "done", automationID: "one", runID: "same")))
    }

    func testCancelledMenuWatcherCannotClearItsReplacement() {
        var menus = NotchMenuObservation()
        let old = menus.begin()
        XCTAssertTrue(menus.update(true, owner: old))
        let replacement = menus.begin()
        XCTAssertFalse(menus.finish(old))
        XCTAssertTrue(menus.isOpen)
        XCTAssertFalse(menus.update(false, owner: old))
        XCTAssertTrue(menus.update(false, owner: replacement), "Closing the menu still triggers a refresh")
        XCTAssertTrue(menus.finish(replacement))
        XCTAssertNil(menus.owner)
    }

    func testEmptyStackAndNonfiniteProgressAreSafe() {
        XCTAssertEqual(NotchQueue.stack([]).kind, .info)
        var a = alert("r", .running)
        for value in [Double.nan, .infinity, -.infinity] {
            a.progress = value
            XCTAssertNil(a.presentation.progress)
            XCTAssertEqual(NotchStyle.statusText(a.presentation), "Running")
            var presentation = a.presentation
            presentation.progress = value
            XCTAssertEqual(NotchStyle.statusText(presentation), "Running")
        }
    }

    func testGeometryGrowsForEachMode() {
        let g = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 180, notchHeight: 32)
        let stack = NotchQueue.stack((0..<6).map { alert("q\($0)", .question) })
        XCTAssertEqual(g.bodyHeight(.pill, alert: nil), 0)
        XCTAssertEqual(g.width(.pill), 180 + 2 * NotchGeometry.pillWing)
        XCTAssertEqual(g.bodyHeight(.detail, alert: stack), NotchGeometry.listHeader + 4 * NotchGeometry.rowHeight + NotchGeometry.listBottom)
        XCTAssertGreaterThan(g.panelFrame(.reply, alert: nil).height, g.panelFrame.height)
        XCTAssertEqual(g.panelFrame.maxY, 982)
    }

    func testApprovalCountsSummary() {
        var c = NotchAlert.ApprovalCounts(); c.moves = 12; c.trash = 3
        XCTAssertEqual(c.summary, "12 moves, 3 to Trash")
        c.moves = 1; c.trash = 0; c.refused = 2
        XCTAssertEqual(c.summary, "1 move, 2 refused")
        XCTAssertEqual(c.total, 1)
        XCTAssertEqual(NotchAlert.ApprovalCounts().summary, "No changes")
    }

    func testOldInitializerKeepsWorking() {
        let a = NotchAlert(id: "x", symbol: "bell", title: "t", message: "m", tone: .failure, actions: [.init("Open", id: "open", primary: true)])
        XCTAssertEqual(a.kind, .failure)
        XCTAssertEqual(a.actions.first?.role, .primary)
        XCTAssertTrue(a.actions.first?.primary ?? false)
    }
}
