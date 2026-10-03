import XCTest
import LauncherCore
@testable import JevLauncher

/// Notch alerts for automations: content, inline answers, Approve all, and delivery records.
@MainActor
final class AutomationNotchTests: XCTestCase {
    private var base: URL!
    /// Proposals refuse /private. Keep proposal fixtures inside the repository.
    private var workURL: URL!
    private var center: AutomationCenter!
    private let fm = FileManager.default

    override func setUp() async throws {
        base = fm.temporaryDirectory.appendingPathComponent("notch-\(UUID().uuidString)")
        workURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".jevcast-test-\(UUID().uuidString)")
        try fm.createDirectory(at: workURL, withIntermediateDirectories: true)
        center = AutomationCenter(isolatedStore: AutomationStore(root: base.appendingPathComponent("Automations")))
    }

    override func tearDown() async throws { try? fm.removeItem(at: base); try? fm.removeItem(at: workURL) }

    private var work: String { workURL.path }

    private func agent() -> Automation {
        Automation(id: AutomationID.make(from: "Tidy"), name: "Tidy",
                   kind: .agent(AgentTask(prompt: "tidy", workingDirectory: work, output: .proposal)), schedule: Schedule(rule: .manual))
    }

    /// A run waiting for approval of one move and one refused folder trash.
    private func pendingApproval() throws -> (Automation, RunRecord) {
        try Data("x".utf8).write(to: URL(fileURLWithPath: work + "/a.txt"))
        try Data("y".utf8).write(to: URL(fileURLWithPath: work + "/b.txt"))
        try fm.createDirectory(atPath: work + "/Done", withIntermediateDirectories: false)
        let a = agent()
        center.save(a)
        var run = RunRecord(id: RunID.make(), automation: center.automation(a.id)!, trigger: .manual, occurrence: nil)
        run.state = .needsApproval; run.finished = Date()
        try center.store.saveRun(run)
        let raw = try JSONSerialization.data(withJSONObject: ["version": 1, "summary": "s", "items": [
            ["id": "m", "op": "move", "from": work + "/a.txt", "to": work + "/Done/a.txt", "reason": "r"],
            ["id": "t", "op": "tag", "path": work + "/b.txt", "tags": ["Red"], "reason": "r"],
            ["id": "d", "op": "trash", "path": work + "/Done", "reason": "folders are refused"]
        ]])
        try center.store.writeRunFile(automationID: a.id, runID: run.id, name: RunEngine.proposalRawFile, data: raw)
        return (a, run)
    }

    func testApproveAllAppliesOnlyCheckedItemsThroughApprove() async throws {
        let (a, run) = try pendingApproval()
        guard case .success(let manifest)? = await center.proposal(for: run) else { return XCTFail("no proposal") }
        let counts = AutomationCenter.counts(manifest)
        XCTAssertEqual(counts.summary, "1 move, 1 tag, 1 refused")
        var alert = AutomationCenter.makeAlert(run, automation: a, hideNames: false)
        AutomationCenter.addCounts(counts, to: &alert)
        XCTAssertEqual(alert.actions.map(\.id), ["approveAll", "review", "later"])

        let outcome = await center.approveAll(run, shown: manifest)
        guard case .applied(let journal) = outcome else { return XCTFail("not applied: \(outcome)") }
        XCTAssertEqual(Set(journal.approvedItems), ["m", "t"], "The refused item is never approved")
        XCTAssertTrue(fm.fileExists(atPath: work + "/Done/a.txt"))
        XCTAssertTrue(fm.fileExists(atPath: work + "/Done"), "The refused trash did not run")
        XCTAssertEqual(center.store.run(automationID: a.id, runID: run.id)?.state, .succeeded)

        let result = AutomationCenter.resultAlert(outcome, run: run, title: "Tidy")
        XCTAssertEqual(result.kind, .success)
        XCTAssertEqual(result.actions.first?.id, "undo")
        XCTAssertEqual(NotchTiming.seconds(for: result.kind, failureSeconds: 8), 10)

        // A second Approve all finds nothing waiting.
        guard case .refused = await center.approveAll(run, shown: manifest) else { return XCTFail("approved twice") }
    }

    func testApproveAllRefusesWhenTheAutomationChanged() async throws {
        let (a, run) = try pendingApproval()
        guard case .success(let manifest)? = await center.proposal(for: run) else { return XCTFail("no proposal") }
        var edited = center.automation(a.id)!
        edited.notes = "changed"
        center.save(edited)
        guard case .refused = await center.approveAll(run, shown: manifest) else { return XCTFail("applied after the automation changed") }
        XCTAssertTrue(fm.fileExists(atPath: work + "/a.txt"))
        XCTAssertEqual(center.store.run(automationID: a.id, runID: run.id)?.state, .needsApproval)
    }

    func testApproveAllRefusesChangedRawProposalAndMissingSnapshot() async throws {
        let (a, run) = try pendingApproval()
        guard case .success(let manifest)? = await center.proposal(for: run) else { return XCTFail("no proposal") }
        guard case .refused = await center.approveAll(run, shown: nil) else { return XCTFail("approved unseen proposal") }
        let raw = try XCTUnwrap(center.store.readRunFile(automationID: a.id, runID: run.id, name: RunEngine.proposalRawFile))
        let changed = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "a.txt", with: "changed.txt").utf8)
        XCTAssertNotEqual(raw, changed)
        try center.store.writeRunFile(automationID: a.id, runID: run.id, name: RunEngine.proposalRawFile, data: changed)
        center.proposals.removeAll()
        // Even a new cache check must not replace the proposal carried by the visible alert.
        _ = await center.proposal(for: run)
        guard case .refused = await center.approveAll(run, shown: manifest) else { return XCTFail("approved changed proposal") }
        XCTAssertTrue(fm.fileExists(atPath: work + "/a.txt"))
        XCTAssertFalse(fm.fileExists(atPath: work + "/Done/changed.txt"))
    }

    func testLateProposalCountsCannotReplaceAChangedOrDismissedAlert() {
        var run = RunRecord(id: RunID.make(), automation: agent(), trigger: .manual, occurrence: nil)
        run.state = .needsApproval
        let expected = AutomationCenter.makeAlert(run, automation: nil, hideNames: false)
        XCTAssertTrue(AutomationCenter.canAddCounts(expected: expected, current: expected))
        XCTAssertFalse(AutomationCenter.canAddCounts(expected: expected, current: nil))
        run.state = .needsInput
        XCTAssertFalse(AutomationCenter.canAddCounts(expected: expected,
                                                    current: AutomationCenter.makeAlert(run, automation: nil, hideNames: false)))
    }

    func testApprovalSelectionAlwaysExcludesRefusedIDs() async throws {
        let (_, run) = try pendingApproval()
        guard case .success(var manifest)? = await center.proposal(for: run) else { return XCTFail("no proposal") }
        manifest.refused["m"] = "Refused"
        XCTAssertEqual(AutomationCenter.approvableItems(manifest), ["t"])
        let current = await center.currentRun(run.automationID, run.id)
        XCTAssertEqual(current, run)
    }

    func testQuestionAlertOffersChoicesAndReply() {
        var run = RunRecord(id: RunID.make(), automation: agent(), trigger: .manual, occurrence: nil)
        run.state = .needsInput; run.finished = Date()
        run.questions = [RunQuestion(round: 1, text: "Old", choices: ["x"], answer: "x"),
                         RunQuestion(round: 2, text: "Which folder?", choices: ["Archive", "Documents"])]
        let alert = AutomationCenter.makeAlert(run, automation: nil, hideNames: false)
        XCTAssertEqual(alert.kind, .question)
        XCTAssertEqual(alert.message, "Which folder?")
        XCTAssertEqual(alert.choices, ["Archive", "Documents"])
        XCTAssertTrue(alert.allowsReply)
        XCTAssertEqual(AutomationCenter.answerText(NotchAlert.choiceAction(1), run: run), "Documents")
        XCTAssertNil(AutomationCenter.answerText(NotchAlert.choiceAction(5), run: run))
        XCTAssertEqual(AutomationCenter.answerText(NotchAlert.replyText("  Put them in Archive "), run: run), "Put them in Archive")
        XCTAssertNil(AutomationCenter.answerText("later", run: run))

        let hidden = AutomationCenter.makeAlert(run, automation: nil, hideNames: true)
        XCTAssertEqual(hidden.message, "It has a question for you.")
        XCTAssertTrue(hidden.choices.isEmpty, "Hidden names hide the question and its choices")
        XCTAssertFalse(hidden.allowsReply)
    }

    func testFailureAndRunningAlerts() {
        var run = RunRecord(id: RunID.make(), automation: agent(), trigger: .manual, occurrence: nil)
        run.state = .failed; run.error = "boom"; run.finished = Date()
        let failure = AutomationCenter.makeAlert(run, automation: nil, hideNames: false)
        XCTAssertEqual(failure.kind, .failure)
        XCTAssertEqual(failure.actions.map(\.id), ["retry", "open", "dismiss"])
        run.state = .running; run.started = Date().addingTimeInterval(-30); run.summary = "Reading files"
        let live = AutomationCenter.runningAlert(run, automation: nil, hideNames: false)
        XCTAssertEqual(live.kind, .running)
        XCTAssertNil(live.detail, "A summary line is not the current step")
        XCTAssertEqual(live.runID, failure.runID, "The failure replaces the running indicator in the queue")
        XCTAssertEqual(live.presentation.visibleActions.map(\.id), ["open"], "Details is the one visible action")
        XCTAssertEqual(live.presentation.overflowActions.first?.role, .destructive, "Cancel stays in the menu")
        XCTAssertNil(AutomationCenter.runningAlert(run, automation: nil, hideNames: true).detail)
    }

    func testAlertRoutingParsesIDs() {
        var opened: [(String?, String?)] = []
        center.openWindow = { opened.append(($0, $1)) }
        XCTAssertTrue(center.handleAlertAction("running:tidy-1/20260926T080000Z-abcd", "open"))
        XCTAssertTrue(center.handleAlertAction(NotchQueue.stackID, "open"))
        XCTAssertTrue(center.handleAlertAction("run:../x/y", "open"), "Ours, but not valid IDs: nothing opens")
        XCTAssertFalse(center.handleAlertAction("test-info-1", "later"))
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened.first?.1, "20260926T080000Z-abcd")
    }

    /// A press outside closes a question or approval as Later: the run still waits for the user, nothing is answered,
    /// approved, or opened, no delivery is recorded by it, and Show notifications can bring the alert back.
    func testLaterLeavesQuestionsAndApprovalsUnfinished() async throws {
        let a = agent()
        center.save(a)
        let saved = try XCTUnwrap(center.automation(a.id))
        var asked = RunRecord(id: RunID.make(), automation: saved, trigger: .manual, occurrence: nil)
        asked.state = .needsInput; asked.finished = Date()
        asked.questions = [RunQuestion(round: 1, text: "Which folder?", choices: ["Archive"])]
        var waiting = RunRecord(id: RunID.make(), automation: saved, trigger: .manual, occurrence: nil)
        waiting.state = .needsApproval; waiting.finished = Date()
        try center.store.saveRun(asked)
        try center.store.saveRun(waiting)
        await center.reloadNow()
        var opened = 0
        center.openWindow = { _, _ in opened += 1 }
        for run in [asked, waiting] {
            let alert = AutomationCenter.makeAlert(run, automation: saved, hideNames: false)
            XCTAssertTrue(alert.offers("later"))
            XCTAssertTrue(center.handleAlertAction(alert.id, "later"))
            let stored = try XCTUnwrap(center.store.run(automationID: a.id, runID: run.id))
            XCTAssertEqual(stored.state, run.state, "still waiting for the user")
            XCTAssertEqual(stored.questions.map(\.answer), run.questions.map(\.answer), "nothing answered")
            XCTAssertFalse(AutomationAlertReceipt.wasDelivered(stored, store: center.store), "Later itself records no delivery")
            XCTAssertTrue(center.alertStillApplies(alert), "Show notifications can bring it back")
        }
        XCTAssertEqual(opened, 0, "Later opens nothing")
    }

    func testDeliveryIsPersistedPerState() throws {
        let a = agent()
        center.save(a)
        var run = RunRecord(id: RunID.make(), automation: center.automation(a.id)!, trigger: .manual, occurrence: nil)
        run.state = .failed; run.finished = Date()
        try center.store.saveRun(run)
        XCTAssertFalse(AutomationAlertReceipt.wasDelivered(run, store: center.store))
        try AutomationAlertReceipt.save(run, store: center.store)
        XCTAssertTrue(AutomationAlertReceipt.wasDelivered(run, store: center.store))
        // A relaunch reads the receipt and does not show it again.
        let read = AutomationReadout.read(center.store)
        let loaded = try XCTUnwrap(read.runs[a.id]?.first { $0.id == run.id })
        XCTAssertTrue(loaded.alerted)
        XCTAssertEqual(AlertDecision.decide(loaded, policy: Policy(), settings: AlertSettings(), now: Date()), .skip)
        // A new state of the same run, such as a retry, alerts again.
        run.attempt = 2
        XCTAssertFalse(AutomationAlertReceipt.wasDelivered(run, store: center.store))
    }
}
