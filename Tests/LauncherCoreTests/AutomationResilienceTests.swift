import XCTest
@testable import LauncherCore

/// Sleep, shutdown, and repeated failures: what the runner does after a gap, when it keeps the Mac awake,
/// and how failures are explained and folded for display without changing what is stored.
final class AutomationResilienceTests: XCTestCase {
    private var root: URL!
    private var store: AutomationStore!
    private let anchor = Date(timeIntervalSince1970: 1_790_000_000)
    private let hours = (0...23).map(String.init).joined(separator: ",")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("resilience-\(UUID().uuidString)")
        store = AutomationStore(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func automation(_ id: String = "backup-a1", rule: Schedule.Rule? = nil, catchUp: CatchUp = .runOnce, enabled: Bool = true) -> Automation {
        Automation(id: id, name: "Backup", kind: .script(ScriptTask(executable: "/bin/true", workingDirectory: "/tmp")),
                   schedule: Schedule(rule: rule ?? .rrule("FREQ=DAILY;BYHOUR=\(hours);BYMINUTE=0"), timeZone: "Europe/London", anchor: anchor),
                   policy: Policy(catchUp: catchUp), enabled: enabled, created: anchor)
    }

    private func run(_ a: Automation, _ id: String, _ state: RunState, at offset: TimeInterval, error: String? = nil) -> RunRecord {
        var r = RunRecord(id: id, automation: a, trigger: .schedule, occurrence: nil, queued: anchor.addingTimeInterval(offset))
        r.state = state; r.started = r.queued; r.finished = r.queued.addingTimeInterval(30); r.error = error
        return r
    }

    // MARK: Catch-up after the Mac was off

    /// Ten hours off: one catch-up run for the newest missed hour, and no run record for the other nine.
    func testHoursOffQueueOneCatchUpAndNoFailedRuns() throws {
        let a = automation()
        try store.save(a)
        let lastRun = anchor.addingTimeInterval(3600 - anchor.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600))
        try store.saveState(AutomationState(lastCovered: lastRun), for: a.id)
        let wake = lastRun.addingTimeInterval(10 * 3600 + 600)

        let due = Scheduler.due(a, lastCovered: lastRun, now: wake)
        XCTAssertEqual(due.runs, [lastRun.addingTimeInterval(10 * 3600)])
        XCTAssertEqual(due.missed, 9)

        guard case .queued(let queued) = OccurrenceClaim(store: store).claimDue(a, now: wake, busy: false) else { return XCTFail("not queued") }
        XCTAssertEqual(queued.state, .queued)
        let runs = store.runs(for: a.id, limit: 50)
        XCTAssertEqual(runs.map(\.id), [queued.id])
        XCTAssertFalse(runs.contains { [.failed, .interrupted].contains($0.state) })
    }

    // MARK: Keep awake on power

    func testKeepAwakeSettingDefaultsOffAndOlderFilesKeepIt() throws {
        XCTAssertFalse(AutomationSettings().keepAwakeOnPower)
        XCTAssertTrue(AutomationSettings().preventIdleSleep, "the active-run setting keeps its default")
        let old = #"{"maxConcurrentRuns":1,"historyDays":30,"codexPath":"","claudePath":"","scriptPath":"/bin","preventIdleSleep":true}"#
        let decoded = try JSONDecoder().decode(AutomationSettings.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.keepAwakeOnPower)
        var on = decoded; on.keepAwakeOnPower = true
        let again = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(again.keepAwakeOnPower)
    }

    func testKeepAwakeOnlyOnPowerWithScheduledWork() {
        var on = AutomationSettings(); on.keepAwakeOnPower = true
        let off = AutomationSettings()
        let now = anchor.addingTimeInterval(3600)
        let hourly = automation()
        func wanted(_ s: AutomationSettings, _ list: [Automation], _ power: KeepAwakePolicy.PowerSource, stopping: Bool = false) -> Bool {
            KeepAwakePolicy.wanted(settings: s, automations: list, power: power, shuttingDown: stopping, now: now)
        }
        XCTAssertTrue(wanted(on, [hourly], .ac))
        XCTAssertFalse(wanted(off, [hourly], .ac), "off by default")
        XCTAssertFalse(wanted(on, [hourly], .battery), "battery sleeps as usual")
        XCTAssertFalse(wanted(on, [hourly], .unknown), "unknown power counts as battery")
        XCTAssertFalse(wanted(on, [hourly], .ac, stopping: true), "released while the runner stops")
        XCTAssertFalse(wanted(on, [], .ac))
        XCTAssertFalse(wanted(on, [automation(enabled: false)], .ac), "paused jobs do not count")
        XCTAssertFalse(wanted(on, [automation(rule: .manual)], .ac), "manual jobs do not count")
        XCTAssertFalse(wanted(on, [automation(rule: .once(now.addingTimeInterval(-60)))], .ac), "a finished one-time job does not count")
        XCTAssertTrue(wanted(on, [automation(rule: .once(now.addingTimeInterval(600)))], .ac))
        XCTAssertFalse(wanted(on, [automation(rule: .rrule("NOT A RULE"))], .ac))
    }

    func testKeepAwakeAssertionIsRenewedBeforeItsTimeoutAndReleased() {
        let t = anchor
        XCTAssertLessThan(KeepAwakePolicy.renewInterval * 2, KeepAwakePolicy.assertionTimeout)
        XCTAssertEqual(KeepAwakePolicy.step(wanted: false, heldSince: nil, now: t), .none)
        XCTAssertEqual(KeepAwakePolicy.step(wanted: true, heldSince: nil, now: t), .create)
        XCTAssertEqual(KeepAwakePolicy.step(wanted: true, heldSince: t, now: t.addingTimeInterval(30)), .none)
        XCTAssertEqual(KeepAwakePolicy.step(wanted: true, heldSince: t, now: t.addingTimeInterval(KeepAwakePolicy.renewInterval)), .renew)
        XCTAssertEqual(KeepAwakePolicy.step(wanted: true, heldSince: t, now: t.addingTimeInterval(-5)), .renew, "a clock that moved back renews")
        XCTAssertEqual(KeepAwakePolicy.step(wanted: false, heldSince: t, now: t.addingTimeInterval(30)), .release)
    }

    // MARK: Explaining failures

    private let divergence = "Exited with code 1. Backup partly blocked. agents: Backup failed: Local main has diverged from origin/main (42 ahead, 42 behind); refusing backup"

    func testGitDivergenceIsNeedsReviewAndStaysFailed() {
        let a = automation()
        let failed = run(a, "20261004T040000Z-occ-1", .failed, at: 0, error: divergence)
        let explained = FailureExplainer.explain(failed, catchUp: .runOnce)
        XCTAssertEqual(explained?.kind, .needsReview)
        XCTAssertEqual(explained?.retryHelps, false)
        XCTAssertTrue(explained?.message.contains("(42 ahead, 42 behind)") == true)
        XCTAssertTrue(explained?.message.contains("does not change Git") == true)
        XCTAssertEqual(failed.state, .failed, "display only")
        XCTAssertNil(FailureExplainer.explain(run(a, "s", .succeeded, at: 0, error: divergence), catchUp: nil), "never on a success")
        XCTAssertNil(FailureExplainer.explain(run(a, "f", .failed, at: 0, error: "Exited with code 2."), catchUp: nil), "unknown causes keep the plain error")
    }

    func testRunnerStopReadsAsInterruptionUnlessAProgramMayRemain() {
        let a = automation()
        var stopped = run(a, "r1", .interrupted, at: 0, error: "The runner stopped during this run. It was not repeated.")
        let once = FailureExplainer.explain(stopped, catchUp: .runOnce)
        XCTAssertEqual(once?.kind, .interrupted)
        XCTAssertEqual(once?.retryHelps, true)
        XCTAssertTrue(once?.message.contains("newest missed time runs once") == true)
        XCTAssertTrue(FailureExplainer.explain(stopped, catchUp: .skip)?.message.contains("Missed times are skipped") == true)
        stopped.orphanPGID = 4242
        XCTAssertNil(FailureExplainer.explain(stopped, catchUp: .runOnce), "a program that may still run keeps its full warning")
    }

    func testRunThatNeverStartedIsNotDescribedAsStoppedDuringTheRun() {
        var late = run(automation(), "q1", .interrupted, at: 0,
                       error: "The runner stopped before this run started, and it is too old to start late.")
        late.started = nil
        let explained = FailureExplainer.explain(late, catchUp: .runOnce)
        XCTAssertEqual(explained?.title, "Not started")
        XCTAssertTrue(explained?.message.contains("before this run started") == true)
        XCTAssertFalse(explained?.message.contains("during this run") == true)
    }

    func testDivergenceIsReadOnlyFromTheErrorNotAModelSummary() {
        var agent = run(automation(), "g1", .failed, at: 0, error: nil)
        agent.summary = "The output diverged from the expected schema (3 ahead, 1 behind)."
        XCTAssertNil(FailureExplainer.explain(agent, catchUp: nil), "a model-written summary is never classified")
        agent.error = "The agent failed: timeout."
        XCTAssertNil(FailureExplainer.explain(agent, catchUp: nil))
    }

    func testDivergenceCountsComeFromTheParenthesisAfterThePhrase() {
        let text = "Exited with code 1. backup (step 2): Local main has diverged from origin/main (5 ahead, 7 behind); refusing"
        XCTAssertEqual(FailureExplainer.divergence(in: text), " (5 ahead, 7 behind)")
        XCTAssertEqual(FailureExplainer.divergence(in: "Exited (2 ahead, 3 behind). main has diverged from origin/main"), "",
                       "a parenthesis before the phrase is not used")
    }

    func testFailedRenewKeepsTheOldAssertionOnlyWellInsideItsTimeout() {
        let t = anchor
        XCTAssertTrue(KeepAwakePolicy.keepsOldAfterFailedRenew(heldSince: t, now: t.addingTimeInterval(KeepAwakePolicy.renewInterval)))
        XCTAssertFalse(KeepAwakePolicy.keepsOldAfterFailedRenew(heldSince: t, now: t.addingTimeInterval(KeepAwakePolicy.assertionTimeout - 30)))
        XCTAssertFalse(KeepAwakePolicy.keepsOldAfterFailedRenew(heldSince: t, now: t.addingTimeInterval(-5)), "a clock that moved back drops it")
    }

    // MARK: Folding repeated failures

    func testRepeatedFailuresFoldIntoOneEntryAndKeepEveryRun() {
        let a = automation(), b = automation("report-b2")
        // Newest first: four identical failures (counts differ), a success, then two older identical failures.
        let aRuns = [run(a, "a7", .failed, at: 700, error: divergence),
                     run(a, "a6", .failed, at: 600, error: divergence.replacingOccurrences(of: "42 ahead", with: "41 ahead")),
                     run(a, "a5", .failed, at: 500, error: divergence),
                     run(a, "a4", .failed, at: 400, error: divergence),
                     run(a, "a3", .succeeded, at: 300),
                     run(a, "a2", .failed, at: 200, error: divergence),
                     run(a, "a1", .failed, at: 100, error: divergence)]
        let bRuns = [run(b, "b2", .succeeded, at: 650), run(b, "b1", .succeeded, at: 450)]
        let history = [a.id: aRuns, b.id: bRuns]
        let all = (aRuns + bRuns).sorted { $0.queued > $1.queued }

        let streaks = RunStreaks.collapse(all, history: history)
        XCTAssertEqual(streaks.map(\.id), ["a7", "b2", "b1", "a3", "a2"], "another automation's runs between them do not split a streak")
        XCTAssertEqual(streaks.first?.runs.map(\.id), ["a7", "a6", "a5", "a4"])
        XCTAssertEqual(streaks.first?.since, anchor.addingTimeInterval(400))
        XCTAssertEqual(streaks.reduce(0) { $0 + $1.count }, all.count, "every run stays reachable")

        // Failed Recently hides the success, but it still ends the newer streak.
        let failedOnly = all.filter { $0.state == .failed }
        XCTAssertEqual(RunStreaks.collapse(failedOnly, history: history).map(\.count), [4, 2])
    }

    func testDifferentFailuresAndStatesDoNotFold() {
        let a = automation()
        let runs = [run(a, "a3", .failed, at: 300, error: divergence),
                    run(a, "a2", .failed, at: 200, error: "Exited with code 2. Disk full."),
                    run(a, "a1", .interrupted, at: 100, error: "Exited with code 2. Disk full.")]
        XCTAssertEqual(RunStreaks.collapse(runs, history: [a.id: runs]).map(\.count), [1, 1, 1])
    }
}
