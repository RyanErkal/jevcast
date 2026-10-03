import XCTest
import LauncherCore
@testable import JevLauncher

/// Delivery evidence and the runner's identity: what counts as shown, and when the runner counts as running.
@MainActor
final class AutomationPresentationTests: XCTestCase {
    private var base: URL!
    private var store: AutomationStore!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-\(UUID().uuidString)")
        store = AutomationStore(root: base.appendingPathComponent("Automations"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func reportRun(_ state: RunState = .succeeded) throws -> (Automation, RunRecord) {
        let a = Automation(id: "client-reports", name: "Sample Client Metrics and Reports", kind: .script(ScriptTask(executable: "/bin/echo", workingDirectory: "/")),
                           schedule: Schedule(rule: .manual), policy: Policy(alertOnSuccess: true))
        try store.save(a)
        var run = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
        run.state = state; run.finished = Date(); run.summary = "Report ready: Sample Client weekly 2026-09-27"
        try store.saveRun(run)
        return (a, run)
    }

    func testSuccessAndInterruptedAlertsOpenTheSavedResult() throws {
        let (a, run) = try reportRun()
        let success = AutomationCenter.makeAlert(run, automation: a, hideNames: false)
        XCTAssertEqual(success.kind, .success)
        XCTAssertEqual(success.message, "Report ready: Sample Client weekly 2026-09-27")
        XCTAssertEqual(success.actions.first?.id, "open")
        var interrupted = run; interrupted.state = .interrupted; interrupted.summary = ""; interrupted.error = "The runner stopped during this run."
        let alert = AutomationCenter.makeAlert(interrupted, automation: a, hideNames: false)
        XCTAssertEqual(alert.kind, .failure)
        XCTAssertEqual(alert.message, "Interrupted: The runner stopped during this run.")
        XCTAssertEqual(AlertText.make(interrupted, name: a.name, hideNames: true).message, "It was interrupted.")
    }

    func testOnlyDrawnAlertsCountAsPresented() {
        func alert(_ id: String, _ kind: NotchAlert.Kind) -> NotchAlert { NotchAlert(id: id, kind: kind, symbol: "x", title: id, message: "") }
        let single = alert("run:a/1", .success)
        XCTAssertEqual(NotchAlertController.presentedAlerts(single, mode: .card).map(\.id), ["run:a/1"])
        XCTAssertEqual(NotchAlertController.presentedAlerts(alert("running:a/1", .running), mode: .pill).map(\.id), [])
        let members = (1...6).map { alert("run:a/\($0)", .success) }
        let stack = NotchQueue.stack(members)
        XCTAssertEqual(NotchAlertController.presentedAlerts(stack, mode: .card).map(\.id), [], "a collapsed stack shows titles only")
        XCTAssertEqual(NotchAlertController.presentedAlerts(stack, mode: .detail).map(\.id), members.prefix(NotchGeometry.maxRows).map(\.id),
                       "only the rows the open list draws")
    }

    func testPresentationProofCarriesThePendingReportsOnce() throws {
        let (_, run) = try reportRun()
        let item = PublicationItem(job: "sample-client:weekly", periodKey: "2026-09-27", title: "Weekly",
                                   artifactHashes: ["/r/2026-09-27-sample-client-weekly.md": String(repeating: "e", count: 64)])
        try store.writeRunFile(automationID: run.automationID, runID: run.id, name: PublicationRecord.fileName,
                               data: JSONEncoder().encode(PublicationRecord(automationID: run.automationID, runID: run.id, items: [item])))
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        try AutomationCenter.savePresentationProof(run, alertID: AutomationCenter.alertID(run), store: store, now: first)
        try AutomationCenter.savePresentationProof(run, alertID: AutomationCenter.alertID(run), store: store, now: first.addingTimeInterval(60))
        let data = try XCTUnwrap(store.readRunFile(automationID: run.automationID, runID: run.id, name: PresentationProof.fileName))
        let proof = try PresentationProof.decoder().decode(PresentationProof.self, from: data)
        XCTAssertEqual(proof.items, [item])
        XCTAssertEqual(proof.presentedAt.timeIntervalSince1970, first.timeIntervalSince1970, accuracy: 0.01, "the first presentation is kept")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"presented_at\" : \"20"), "ISO dates for the publish script")
    }

    func testNoProofWithoutAPublication() throws {
        let (_, run) = try reportRun()
        try AutomationCenter.savePresentationProof(run, alertID: AutomationCenter.alertID(run), store: store, now: Date())
        XCTAssertNil(try? store.readRunFile(automationID: run.automationID, runID: run.id, name: PresentationProof.fileName))
    }

    func testStaleRunnerIsNotRunning() {
        let now = Date()
        let expected = AutomationCenter.RunnerIdentity(version: "1.17.0", build: "35", executable: "/Applications/Jevcast.app/Contents/MacOS/jevcast-runner")
        func beat(_ version: String, build: String?, path: String?) -> RunnerHeartbeat {
            RunnerHeartbeat(pid: 1, started: now.addingTimeInterval(-60), heartbeat: now, version: version, signedBuild: true, executable: path, build: build)
        }
        let current = beat("1.17.0", build: "35", path: expected.executable)
        XCTAssertEqual(AutomationCenter.runnerStatus(signed: true, service: .enabled, heartbeat: current, enabledSince: nil, now: now, expected: expected),
                       .running(since: current.started))
        XCTAssertEqual(AutomationCenter.runnerStatus(signed: true, service: .enabled, heartbeat: beat("1.16.1", build: nil, path: nil),
                                                     enabledSince: nil, now: now, expected: expected), .staleHelper("1.16.1"))
        XCTAssertEqual(AutomationCenter.runnerStatus(signed: true, service: .enabled, heartbeat: beat("1.17.0", build: "35", path: "/tmp/Jevcast.app/Contents/MacOS/jevcast-runner"),
                                                     enabledSince: nil, now: now, expected: expected), .staleHelper("1.17.0"), "another copy of the same version")
        XCTAssertEqual(AutomationCenter.runnerStatus(signed: true, service: .enabled, heartbeat: beat("1.17.0", build: "34", path: expected.executable),
                                                     enabledSince: nil, now: now, expected: expected), .staleHelper("1.17.0"), "another build")
    }
}

@MainActor
final class AutomationAlertKeepTests: XCTestCase {
    /// A shown success or failure is not withdrawn when its receipt makes the next reload see `alerted`.
    func testDrawnTerminalAlertsSurviveTheReceiptReload() {
        let a = Automation(id: "keep-1", name: "K", kind: .script(ScriptTask(executable: "/bin/echo", workingDirectory: "/")), schedule: Schedule(rule: .manual))
        func run(_ state: RunState, alerted: Bool) -> RunRecord {
            var r = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
            r.state = state; r.alerted = alerted; r.finished = Date(); return r
        }
        let success = run(.succeeded, alerted: true), failure = run(.failed, alerted: true), queued = run(.interrupted, alerted: false)
        let question = run(.needsInput, alerted: true), answered = run(.running, alerted: true)
        let keep = AutomationCenter.alertsToKeep([success, failure, queued, question, answered])
        XCTAssertTrue(keep.contains(AutomationCenter.alertID(success)))
        XCTAssertTrue(keep.contains(AutomationCenter.alertID(failure)))
        XCTAssertTrue(keep.contains(AutomationCenter.alertID(queued)), "an alert not drawn yet stays queued")
        XCTAssertTrue(keep.contains(AutomationCenter.alertID(question)))
        XCTAssertFalse(keep.contains(AutomationCenter.alertID(answered)), "a resolved question is withdrawn")
    }
}
