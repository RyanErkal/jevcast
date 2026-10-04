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

    // MARK: A press outside

    func testAPressOutsideReturnsRunningWorkToItsPillAndNeverEndsIt() throws {
        var q = NotchQueue()
        let one = running("one")
        q.add(one)
        XCTAssertEqual(NotchAlertController.outsideClick(shown: one, mode: .detail, queue: q), .rest, "the open card rests; nothing is cancelled")
        XCTAssertNil(NotchAlertController.outsideClick(shown: one, mode: .pill, queue: q), "the pill is already minimized")
        q.add(running("two"))
        let list = try XCTUnwrap(q.presentation)
        XCTAssertEqual(NotchAlertController.outsideClick(shown: list, mode: .detail, queue: q), .rest)
        XCTAssertNil(NotchAlertController.outsideClick(shown: list, mode: .pill, queue: q))
    }

    func testAPressOutsideClosesOtherAlertsAsLaterReplyIncluded() throws {
        var q = NotchQueue()
        q.add(running("busy"))
        let asked = question("run:q/1")
        q.add(asked)
        XCTAssertEqual(NotchAlertController.outsideClick(shown: asked, mode: .card, queue: q), .later([asked]))
        XCTAssertEqual(NotchAlertController.outsideClick(shown: asked, mode: .reply, queue: q), .later([asked]), "an open reply closes too")
        let approval = alert("run:a/1", .approval, actions: [.init("Review", id: "review", primary: true), .init("Later", id: "later")])
        q.add(approval)
        let stack = try XCTUnwrap(q.presentation)
        for mode in [NotchState.Mode.card, .detail, .reply] {
            XCTAssertEqual(NotchAlertController.outsideClick(shown: stack, mode: mode, queue: q), .later([asked, approval]),
                           "the whole stack goes, never the running card waiting behind it (\(mode))")
        }
        // The queue's current version goes, so an update that arrived after the last draw is not left behind.
        var recounted = approval
        recounted.message = "12 moves"
        q.add(recounted)
        XCTAssertEqual(NotchAlertController.outsideClick(shown: stack, mode: .card, queue: q), .later([asked, recounted]))
        XCTAssertNil(NotchAlertController.outsideClick(shown: alert("run:f/1", .failure), mode: .card, queue: q),
                     "an alert that has already gone closes nothing")
    }

    func testAPressOutsideNeverRemovesAnAlertWithoutLater() throws {
        var q = NotchQueue()
        // The result of Approve all: Undo and Open, no Later. It could not come back from Show notifications.
        let result = alert("result:t/1", .success, actions: [.init("Undo", id: "undo", primary: true), .init("Open", id: "open")])
        q.add(result)
        XCTAssertNil(NotchAlertController.outsideClick(shown: result, mode: .card, queue: q), "the card stays as it is")
        XCTAssertEqual(NotchAlertController.outsideClick(shown: result, mode: .detail, queue: q), .rest, "an open card only rests")
        let failure = alert("run:f/1", .failure, actions: [.init("Retry", id: "retry", primary: true), .init("Dismiss", id: "dismiss")])
        q.add(failure)
        let both = try XCTUnwrap(q.presentation)
        XCTAssertEqual(NotchAlertController.outsideClick(shown: both, mode: .detail, queue: q), .rest,
                       "a list where nothing offers Later rests and keeps every row")
        XCTAssertNil(NotchAlertController.outsideClick(shown: both, mode: .card, queue: q))
    }

    func testAPressOutsideOnAMixedStackMovesOnlyTheAlertsThatOfferLater() throws {
        var q = NotchQueue()
        let asked = question("run:q/1")
        let result = alert("result:t/1", .success, actions: [.init("Undo", id: "undo", primary: true), .init("Open", id: "open")])
        let failure = alert("run:f/1", .failure, actions: [.init("Retry", id: "retry", primary: true), .init("Dismiss", id: "dismiss")])
        for a in [asked, result, failure] { q.add(a) }
        let stack = try XCTUnwrap(q.presentation)
        for mode in [NotchState.Mode.card, .detail, .reply] {
            XCTAssertEqual(NotchAlertController.outsideClick(shown: stack, mode: mode, queue: q), .later([asked]),
                           "only the question goes to Later; the result and the failure stay (\(mode))")
        }
        // What stays still shows, as a stack of its own.
        _ = q.removeAll { $0.id == asked.id }
        let rest = try XCTUnwrap(q.presentation)
        XCTAssertEqual(rest.stack.map(\.id), [failure.id, result.id])
        XCTAssertEqual(NotchAlertController.restingMode(for: rest), .card)
    }

    // MARK: The outside watch

    func testTheOutsideWatchRunsOnlyWhileAnOpenIslandShows() {
        typealias C = NotchAlertController
        for mode in [NotchState.Mode.card, .detail, .reply] {
            XCTAssertTrue(C.watchesOutside(visible: true, showing: true, closing: false, available: true, mode: mode))
        }
        XCTAssertFalse(C.watchesOutside(visible: true, showing: true, closing: false, available: true, mode: .pill),
                       "a pill (also after a press rested it) stops the watch")
        XCTAssertFalse(C.watchesOutside(visible: false, showing: true, closing: false, available: true, mode: .card), "hidden panel")
        XCTAssertFalse(C.watchesOutside(visible: true, showing: false, closing: false, available: true, mode: .card), "nothing shows")
        XCTAssertFalse(C.watchesOutside(visible: true, showing: true, closing: true, available: true, mode: .card),
                       "a press that emptied the queue closes the island and stops the watch")
        XCTAssertFalse(C.watchesOutside(visible: true, showing: true, closing: false, available: false, mode: .card),
                       "locked session or a menu under the notch")
    }

    func testAPressBeforeTheCardSettledOrOnTheIslandDoesNothing() {
        func accepts(visible: Bool = true, available: Bool = true, expanded: Bool = true, closing: Bool = false,
                     ready: Bool = true, ownMenu: Bool = false, inside: Bool = false) -> Bool {
            NotchAlertController.acceptsOutsidePress(visible: visible, available: available, expanded: expanded, closing: closing,
                                                     ready: ready, ownMenu: ownMenu, inside: inside)
        }
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(ready: false), "a press while the card still grows (before inputReadyAt) does nothing")
        XCTAssertFalse(accepts(expanded: false), "not grown yet")
        XCTAssertFalse(accepts(inside: true), "a press on the island itself")
        XCTAssertFalse(accepts(ownMenu: true), "the island's own menu is open or just closed")
        XCTAssertFalse(accepts(closing: true))
        XCTAssertFalse(accepts(visible: false))
        XCTAssertFalse(accepts(available: false))
    }

    func testTheOutsideMonitorStartsOnceAndStops() {
        var presses = 0
        let watch = NotchOutsideClick { _ in presses += 1 }
        XCTAssertFalse(watch.isWatching)
        watch.start()
        XCTAssertTrue(watch.isWatching)
        watch.start()
        watch.stop()
        XCTAssertFalse(watch.isWatching, "a second start adds no second monitor, so one stop ends the watch")
        watch.stop()
        XCTAssertFalse(watch.isWatching)
        XCTAssertEqual(presses, 0)
    }

    // MARK: Each state of a run is reported as shown

    func testASecondQuestionForTheSameRunIsReportedAgain() {
        var log = NotchPresentedLog()
        let first = question("run:q/1", "Which folder?")
        XCTAssertEqual(log.record([first]).map(\.message), ["Which folder?"])
        XCTAssertTrue(log.record([first]).isEmpty, "drawn again unchanged: one report")
        // Answered; the alert leaves the queue.
        log.keep([])
        let second = question("run:q/1", "Keep the old copies?")
        XCTAssertEqual(log.record([second]).map(\.message), ["Keep the old copies?"], "same ID, new question: reported")
        // Replaced in place, without leaving the queue, by yet another question.
        let third = question("run:q/1", "And the PDFs?")
        log.keep([third])
        XCTAssertEqual(log.record([third]).map(\.message), ["And the PDFs?"])
        log.keep([third])
        XCTAssertTrue(log.record([third]).isEmpty)
    }

    func testAnApprovalThatBecomesASuccessIsReportedAgain() {
        var log = NotchPresentedLog()
        let approval = NotchAlert(id: "run:t/1", kind: .approval, symbol: "bell", title: "Desktop tidy", message: "4 changes",
                                  actions: [.init("Review", id: "review", primary: true), .init("Later", id: "later")],
                                  automationID: "t", runID: "1")
        XCTAssertEqual(log.record([approval]).count, 1)
        // `show` replaces it in place by ID: the run finished and the automation alerts on success.
        var q = NotchQueue()
        q.add(approval)
        let success = NotchAlert(id: "run:t/1", kind: .success, symbol: "bell", title: "Desktop tidy", message: "4 changes",
                                 actions: [.init("Open", id: "open", primary: true), .init("Dismiss", id: "dismiss")],
                                 automationID: "t", runID: "1")
        q.add(success)
        log.keep(q.entries.map(\.alert))
        XCTAssertEqual(log.record([success]).map(\.kind), [.success])
        XCTAssertTrue(log.keys.allSatisfy { $0.kind == .success }, "the approval's key went when it changed")
    }

    // MARK: An unsent reply comes back with its exact question

    func testAnUnsentReplyReturnsOnlyWithItsExactQuestion() {
        let state = NotchState()
        let asked = question("run:q/1")
        state.alert = asked
        state.keepDraft("ignored")
        XCTAssertTrue(state.drafts.isEmpty, "only an open reply keeps text")
        state.replyTarget = asked.id
        state.mode = .reply
        state.keepDraft("Put them in Archive")
        // A press outside closes it as Later.
        state.endReply()
        XCTAssertEqual(state.replyDraft, "", "no reply is open")
        // Show notifications brings the question back, here inside a stack, and Reply opens again.
        state.alert = NotchQueue.stack([asked, alert("run:f/1", .failure)])
        state.replyTarget = asked.id
        state.mode = .reply
        XCTAssertEqual(state.replyDraft, "Put them in Archive")
        state.alert = question("run:q/1", "Which folder now?")
        XCTAssertEqual(state.replyDraft, "", "the same run asking something else never gets the old answer")
        state.alert = asked
        state.keepDraft("")
        XCTAssertEqual(state.replyDraft, "", "clearing the field forgets it")
        state.keepDraft("Archive")
        state.forgetDraft(asked.id)
        XCTAssertEqual(state.replyDraft, "")
    }

    func testADraftLastsOnlyWhileItsQuestionCanComeBack() {
        let asked = question("run:q/1")
        let draft = NotchState.Draft(question: asked, text: "Archive")
        var q = NotchQueue()
        q.add(asked)
        XCTAssertTrue(NotchAlertController.draftStillWaits(draft, queue: q, recent: []), "on screen or queued")
        q.remove(asked.id)
        XCTAssertTrue(NotchAlertController.draftStillWaits(draft, queue: q, recent: [[asked]]), "closed as Later, in Show notifications")
        XCTAssertFalse(NotchAlertController.draftStillWaits(draft, queue: q, recent: []), "answered elsewhere and gone")
        q.add(question("run:q/1", "Which folder now?"))
        XCTAssertFalse(NotchAlertController.draftStillWaits(draft, queue: q, recent: []), "the run asked something else")
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
