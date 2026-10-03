import AppKit
import XCTest
@testable import JevLauncher

/// Late presses, superseded animations, timers for what is drawn, and a reply that outlives its container.
@MainActor
final class NotchInteractionTests: XCTestCase {
    private func running(_ automation: String) -> NotchAlert {
        NotchAlert(id: "running:\(automation)/r", kind: .running, symbol: "bolt", title: automation, message: "Running",
                   actions: [.init("Details", id: NotchAlert.detailsAction),
                             .init("Cancel Run", id: "cancel", role: .destructive, menuOnly: true)],
                   automationID: automation, runID: "r")
    }

    private func alert(_ id: String, _ kind: NotchAlert.Kind, actions: [NotchAlert.Action] = [.init("Open", id: "open")]) -> NotchAlert {
        NotchAlert(id: id, kind: kind, symbol: "bell", title: id, message: "m", actions: actions)
    }

    private func question(_ id: String, _ text: String = "Which folder?") -> NotchAlert {
        NotchAlert(id: id, kind: .question, symbol: "bell", title: id, message: text,
                   actions: [.init("Reply…", id: NotchAlert.replyAction), .init("Later", id: "later")], allowsReply: true)
    }

    // MARK: A menu that returns late acts only on its own alert

    func testCancelFromAMenuOpenedOnRunAIsDroppedOnceRunBShows() throws {
        var q = NotchQueue()
        let a = running("a"), b = running("b")
        q.add(a)
        XCTAssertEqual(NotchAlertController.actionTarget("cancel", origin: a.id, shown: try XCTUnwrap(q.presentation), queue: q), .alert(a))
        // A's Cancel Run menu is open. A finishes and B starts before the menu returns.
        q.remove(a.id)
        q.add(b)
        let shown = try XCTUnwrap(q.presentation)
        XCTAssertEqual(shown.id, b.id)
        XCTAssertNil(NotchAlertController.actionTarget("cancel", origin: a.id, shown: shown, queue: q), "A's cancel never reaches B")
        XCTAssertEqual(NotchAlertController.actionTarget("cancel", origin: b.id, shown: shown, queue: q), .alert(b))

        // A run that moves on replaces its card; the old card's button does nothing.
        q.add(NotchAlert(id: "run:b/r", kind: .failure, symbol: "bolt", title: "b", message: "Failed",
                         actions: [.init("Retry", id: "retry", primary: true)], automationID: "b", runID: "r"))
        XCTAssertNil(NotchAlertController.actionTarget("cancel", origin: b.id, shown: try XCTUnwrap(q.presentation), queue: q))
    }

    func testALatePressNeedsTheActionStillOfferedAndTheStackStillShown() throws {
        var q = NotchQueue()
        let approval = alert("run:t/1", .approval, actions: [.init("Approve all", id: "approveAll", primary: true), .init("Later", id: "later")])
        q.add(approval)
        var recounted = approval
        recounted.actions = [.init("Review", id: "review", primary: true), .init("Later", id: "later")]
        q.add(recounted)
        let shown = try XCTUnwrap(q.presentation)
        XCTAssertNil(NotchAlertController.actionTarget("approveAll", origin: approval.id, shown: shown, queue: q),
                     "the same alert no longer offers Approve all")
        XCTAssertNotNil(NotchAlertController.actionTarget("review", origin: approval.id, shown: shown, queue: q))
        XCTAssertNotNil(NotchAlertController.actionTarget(NotchAlert.dismissAction, origin: approval.id, shown: shown, queue: q))
        XCTAssertNil(NotchAlertController.actionTarget("later", origin: NotchQueue.stackID, shown: shown, queue: q),
                     "a stack's Later does nothing once the stack has gone")
        q.add(alert("run:f/1", .failure))
        let stack = try XCTUnwrap(q.presentation)
        guard case .stack(let members)? = NotchAlertController.actionTarget("later", origin: NotchQueue.stackID, shown: stack, queue: q)
        else { return XCTFail("the stack's own Later") }
        XCTAssertEqual(members.map(\.id), ["run:t/1", "run:f/1"])
        let asked = question("q1")
        XCTAssertTrue(asked.offers(NotchAlert.replyText("Archive")))
        var choices = asked; choices.choices = ["A", "B"]
        XCTAssertTrue(choices.offers(NotchAlert.choiceAction(1)))
        XCTAssertFalse(choices.offers(NotchAlert.choiceAction(2)))
    }

    // MARK: Only the current presentation records what was shown

    func testASupersededAnimationRecordsNothing() {
        var tickets = NotchPresentationTickets()
        let a = tickets.issue(alertID: "run:a/1", mode: .card)
        let b = tickets.issue(alertID: "run:b/1", mode: .card)
        XCTAssertFalse(tickets.isCurrent(a), "A's completion arrives while B morphs in: no receipt for anything")
        XCTAssertTrue(tickets.isCurrent(b))
        let bList = tickets.issue(alertID: "run:b/1", mode: .detail)
        XCTAssertFalse(tickets.isCurrent(b), "B's own earlier morph is superseded by its mode change")
        XCTAssertTrue(tickets.isCurrent(bList))
        tickets.invalidate()
        XCTAssertFalse(tickets.isCurrent(bList), "hiding or closing voids the current presentation")
        let againA = tickets.issue(alertID: "run:a/1", mode: .card)
        XCTAssertNotEqual(againA, a, "A shown again never matches its old completion")
        XCTAssertTrue(tickets.isCurrent(againA))
    }

    // MARK: Timers run only for what is drawn

    func testUndrawnAlertsWaitAndEachGetsItsFullTimeWhenDrawn() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var q = NotchQueue()
        let ids = (1...5).map { "run:s/\($0)" }
        for id in ids { q.add(alert(id, .success)) }
        func drawn(_ mode: NotchState.Mode) throws -> Set<String> {
            Set(NotchAlertController.presentedAlerts(try XCTUnwrap(q.presentation), mode: mode).map(\.id))
        }
        // A collapsed stack shows titles only: nothing counts down, and nothing is left for a busy loop to wake for.
        q.startTimers(now: now, drawn: try drawn(.card))
        XCTAssertNil(q.nextDeadline)
        XCTAssertTrue(q.expire(now: now.addingTimeInterval(3600)).isEmpty)
        // The open list draws four rows; the fifth waits.
        q.startTimers(now: now, drawn: try drawn(.detail))
        XCTAssertEqual(q.entries.filter { $0.deadline != nil }.map(\.alert.id), Array(ids.prefix(NotchGeometry.maxRows)))
        let seconds = NotchTiming.resultSeconds
        XCTAssertEqual(q.expire(now: now.addingTimeInterval(seconds)).map(\.id), Array(ids.prefix(4)))
        // The fifth is drawn now, as a card of its own, and gets its full time from here.
        let later = now.addingTimeInterval(seconds)
        q.startTimers(now: later, drawn: try drawn(.card))
        XCTAssertEqual(q.entries.first?.deadline, later.addingTimeInterval(seconds))
        // Hidden again (here: nothing drawn) it waits, and starts in full when drawn once more.
        q.startTimers(now: later.addingTimeInterval(4), drawn: [])
        XCTAssertNil(q.nextDeadline)
    }

    /// The ring sits where the pill is clicked to open; its window-server spinner must never take that click.
    func testTheSpinnerPassesClicksToThePill() {
        let spinner = NotchSpinner.SpinnerView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        spinner.style(tint: .white, line: 2)
        spinner.layout()
        XCTAssertNil(spinner.hitTest(NSPoint(x: 7, y: 7)))
    }

    // MARK: A reply outlives its container

    func testAReplyStaysWhileItsExactQuestionStays() {
        let asked = question("run:q/1")
        let other = alert("run:f/1", .failure)
        let stack = NotchQueue.stack([asked, other])
        XCTAssertEqual(NotchAlertController.nextMode(previous: asked, previousMode: .reply, next: stack, replyTarget: asked.id), .reply,
                       "another alert arriving turns the card into a stack; the reply stays")
        XCTAssertEqual(NotchAlertController.nextMode(previous: stack, previousMode: .reply, next: asked, replyTarget: asked.id), .reply,
                       "and back to the single question")
        let reworded = NotchQueue.stack([question("run:q/1", "A different question?"), other])
        XCTAssertEqual(NotchAlertController.nextMode(previous: stack, previousMode: .reply, next: reworded, replyTarget: asked.id), .card,
                       "a changed question closes the reply")
        XCTAssertEqual(NotchAlertController.nextMode(previous: stack, previousMode: .reply, next: other, replyTarget: asked.id), .card,
                       "a withdrawn question closes it too")
    }

    func testAReplyKeepsItsViewIdentityAcrossContainers() {
        let asked = question("run:q/1")
        let stack = NotchQueue.stack([asked, alert("run:f/1", .failure)])
        let single = NotchIsland.contentKey(alert: asked, mode: .reply, replyTarget: asked.id)
        XCTAssertEqual(single, NotchIsland.contentKey(alert: stack, mode: .reply, replyTarget: asked.id),
                       "same field, draft, and focus")
        XCTAssertNotEqual(NotchIsland.contentKey(alert: asked, mode: .card, replyTarget: nil),
                          NotchIsland.contentKey(alert: stack, mode: .card, replyTarget: nil),
                          "outside a reply a new container still cross-fades")
    }
}
