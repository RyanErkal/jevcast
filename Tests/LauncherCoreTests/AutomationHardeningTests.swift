import XCTest
@testable import LauncherCore

/// Occurrence claims, orphaned child cleanup, approved program identity, and old-file decoding.
final class AutomationHardeningTests: XCTestCase {
    var dir: URL!
    var store: AutomationStore!
    let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("harden-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AutomationStore(root: dir.appendingPathComponent("Automations"))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    // MARK: Occurrence claims

    /// Hourly in UTC from 08:00; "now" is 10:00:30, so the 10:00 occurrence is due.
    let anchor = ISO8601DateFormatter().date(from: "2026-09-26T08:00:00Z")!
    var now: Date { anchor.addingTimeInterval(2 * 3600 + 30) }
    var occurrence: Date { anchor.addingTimeInterval(2 * 3600) }

    func hourly() throws -> Automation {
        let a = Automation(id: "hourly-1", name: "Hourly", kind: .script(ScriptTask(executable: "/bin/echo", workingDirectory: dir.path)),
                           schedule: Schedule(rule: .rrule("FREQ=HOURLY"), timeZone: "UTC", anchor: anchor), enabled: true)
        try store.save(a)
        return a
    }

    func testOccurrenceRunIDIsStableValidAndSortsByTime() {
        let id = RunID.occurrence(automationID: "hourly-1", date: occurrence)
        XCTAssertTrue(RunID.isValid(id))
        XCTAssertEqual(id, RunID.occurrence(automationID: "hourly-1", date: occurrence))
        XCTAssertTrue(id.hasPrefix("20260926T100000Z-occ-"))
        XCTAssertNotEqual(id, RunID.occurrence(automationID: "hourly-2", date: occurrence))
        XCTAssertNotEqual(id, RunID.occurrence(automationID: "hourly-1", date: occurrence.addingTimeInterval(3600)))
    }

    func testClaimQueuesOnceThenAdvancesState() throws {
        let a = try hourly()
        let claim = OccurrenceClaim(store: store)
        guard case .queued(let run) = claim.claimDue(a, now: now, busy: false) else { return XCTFail("not queued") }
        XCTAssertEqual(run.id, RunID.occurrence(automationID: a.id, date: occurrence))
        XCTAssertEqual(run.occurrence, occurrence)
        XCTAssertEqual(store.state(for: a.id).lastCovered, occurrence)
        XCTAssertEqual(claim.claimDue(a, now: now.addingTimeInterval(30), busy: false), .nothing)
        XCTAssertEqual(store.runs(for: a.id, limit: 10).count, 1)
    }

    /// The runner crashed after writing the run and before writing state.json.
    func testCrashAfterRunWriteBeforeStateWriteDoesNotRepeat() throws {
        let a = try hourly()
        let id = RunID.occurrence(automationID: a.id, date: occurrence)
        XCTAssertTrue(try store.createRun(RunRecord(id: id, automation: a, trigger: .schedule, occurrence: occurrence)))
        XCTAssertNil(store.state(for: a.id).lastCovered)

        let result = OccurrenceClaim(store: store).claimDue(a, now: now, busy: false)
        XCTAssertEqual(result, .nothing, "the existing run covers the occurrence")
        XCTAssertEqual(store.runs(for: a.id, limit: 10).map(\.id), [id])
        XCTAssertEqual(store.state(for: a.id).lastCovered, occurrence, "state catches up")
    }

    /// Even when state says nothing was covered, a run under the fixed ID is never written twice.
    func testExistingRunIDIsNeverOverwritten() throws {
        let a = try hourly()
        let id = RunID.occurrence(automationID: a.id, date: occurrence)
        var first = RunRecord(id: id, automation: a, trigger: .schedule, occurrence: occurrence)
        first.state = .succeeded
        XCTAssertTrue(try store.createRun(first))
        var second = first; second.state = .queued
        XCTAssertFalse(try store.createRun(second))
        XCTAssertEqual(store.run(automationID: a.id, runID: id)?.state, .succeeded)
    }

    func testFailedStateWriteStillPreventsDuplicates() throws {
        let a = try hourly()
        // A folder where state.json belongs makes every state write fail.
        try fm.createDirectory(at: store.root.appendingPathComponent("\(a.id)/state.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.saveState(AutomationState(lastCovered: occurrence), for: a.id))

        let claim = OccurrenceClaim(store: store)
        guard case .queued = claim.claimDue(a, now: now, busy: false) else { return XCTFail("not queued") }
        XCTAssertNil(store.state(for: a.id).lastCovered)
        XCTAssertEqual(claim.claimDue(a, now: now.addingTimeInterval(30), busy: false), .nothing)
        XCTAssertEqual(store.runs(for: a.id, limit: 10).count, 1)
    }

    func testFailedRunWriteLeavesOccurrenceUnclaimed() throws {
        let a = try hourly()
        // A file where the runs folder belongs makes the run write fail.
        try Data().write(to: store.root.appendingPathComponent("\(a.id)/runs"))
        guard case .failed = OccurrenceClaim(store: store).claimDue(a, now: now, busy: false) else { return XCTFail("expected failure") }
        XCTAssertNil(store.state(for: a.id).lastCovered, "state must not advance past an occurrence with no run")
    }

    func testBusySkipsWithoutRun() throws {
        let a = try hourly()
        XCTAssertEqual(OccurrenceClaim(store: store).claimDue(a, now: now, busy: true), .skipped)
        XCTAssertEqual(store.state(for: a.id).lastCovered, occurrence)
        XCTAssertTrue(store.runs(for: a.id, limit: 10).isEmpty)
    }

    // MARK: Orphaned children

    /// Starts `/bin/sleep` in its own process group on a background thread and returns its PID.
    func startSleep(_ supervisor: ProcessSupervisor, done: XCTestExpectation) -> pid_t {
        let started = DispatchSemaphore(value: 0)
        let box = PIDBox()
        DispatchQueue.global().async {
            let launch = ProcessLaunch(executable: "/bin/sleep", arguments: ["30"], environment: [:], workingDirectory: "", stdin: Data())
            _ = supervisor.runRecording(launch, timeout: 60, onStart: { box.pid = $0; started.signal() }, onLine: { _ in })
            done.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        return box.pid
    }

    func testOrphanedChildGroupIsStoppedOnlyWhenStartTimeMatches() throws {
        let a = try hourly()
        let supervisor = ProcessSupervisor()
        let done = expectation(description: "sleep ended")
        let pid = startSleep(supervisor, done: done)
        XCTAssertEqual(ProcessInfoReader.groupID(pid), pid, "the child leads its own group")
        let start = try XCTUnwrap(ProcessInfoReader.startTime(pid))

        var run = RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil)
        run.state = .running
        run.ownerPID = 999_999; run.ownerStart = Date()
        run.childPGID = pid
        run.childStart = start.addingTimeInterval(-5)
        XCTAssertEqual(OrphanRecovery.stopChild(of: run, grace: 1), .notOurs, "a PID match alone is not enough")
        XCTAssertTrue(ProcessInfoReader.groupExists(pid))

        run.childStart = start
        let recovered = OrphanRecovery.interrupt(run, grace: 5)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertTrue(recovered.error?.contains("was stopped") == true, recovered.error ?? "")
        XCTAssertNil(recovered.childPGID); XCTAssertNil(recovered.ownerPID)
        wait(for: [done], timeout: 10)
        XCTAssertFalse(ProcessInfoReader.groupExists(pid))
    }

    func testOrphanWithoutChildIsJustInterrupted() throws {
        var run = RunRecord(id: RunID.make(), automation: try hourly(), trigger: .manual, occurrence: nil)
        run.state = .running
        XCTAssertEqual(OrphanRecovery.stopChild(of: run), .noChild)
        XCTAssertEqual(OrphanRecovery.interrupt(run).state, .interrupted)
        XCTAssertFalse(OrphanRecovery.ownerIsAlive(run))
    }

    func testEngineRecordsChildGroupWhileRunning() throws {
        let a = Automation(id: "sleepy-1", name: "S", kind: .script(ScriptTask(executable: "/bin/sleep", arguments: ["2"], workingDirectory: dir.path)),
                           schedule: Schedule(rule: .manual))
        try store.save(a)
        let run = RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil)
        let engine = RunEngine(store: store, context: RunEngine.Context(settings: AutomationSettings(), retryDelay: 0.01))
        let done = expectation(description: "run")
        let finalBox = RunBox()
        DispatchQueue.global().async { finalBox.run = engine.execute(run, automation: a); done.fulfill() }
        var seen: RunRecord?
        for _ in 0..<100 {
            if let r = store.run(automationID: a.id, runID: run.id), r.childPGID != nil { seen = r; break }
            usleep(20_000)
        }
        let during = try XCTUnwrap(seen)
        XCTAssertEqual(during.childPGID.flatMap(ProcessInfoReader.groupID), during.childPGID)
        XCTAssertEqual(during.childPGID.flatMap(ProcessInfoReader.startTime), during.childStart)
        wait(for: [done], timeout: 15)
        XCTAssertEqual(finalBox.run?.state, .succeeded)
        XCTAssertNil(store.run(automationID: a.id, runID: run.id)?.childPGID)
    }

    // MARK: Approved program identity

    func script(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("job-\(UUID().uuidString.prefix(6)).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    func testChangedScriptIsRefused() throws {
        let path = try script("echo one")
        var a = Automation(id: "prog-1", name: "P", kind: .script(ScriptTask(executable: path, workingDirectory: dir.path)), schedule: Schedule(rule: .manual))
        a.recordApprovedPrograms(settings: AutomationSettings())
        XCTAssertNotNil(a.approvedProgram?.sha256)
        try store.save(a)
        let engine = RunEngine(store: store, context: RunEngine.Context(settings: AutomationSettings(), retryDelay: 0.01))
        XCTAssertEqual(engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a).state, .succeeded)

        try "#!/bin/sh\necho two\n".write(toFile: path, atomically: false, encoding: .utf8)
        let refused = engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a)
        XCTAssertEqual(refused.state, .failed)
        XCTAssertEqual(refused.error, RunEngine.programChanged)
        XCTAssertNil(refused.exitCode, "the changed program never started")

        // Saving again approves the new version.
        a.recordApprovedPrograms(settings: AutomationSettings())
        XCTAssertEqual(engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a).state, .succeeded)
    }

    func testMissingScriptIsRefusedWhenApproved() throws {
        let path = try script("echo one")
        var a = Automation(id: "prog-2", name: "P", kind: .script(ScriptTask(executable: path, workingDirectory: dir.path)), schedule: Schedule(rule: .manual))
        a.recordApprovedPrograms(settings: AutomationSettings())
        try store.save(a)
        try fm.removeItem(atPath: path)
        let engine = RunEngine(store: store, context: RunEngine.Context(settings: AutomationSettings(), retryDelay: 0.01))
        XCTAssertEqual(engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a).error,
                       RunEngine.programChanged)
    }

    func testLargeProgramUsesSizeAndTimeOnly() throws {
        let url = dir.appendingPathComponent("big")
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: ProgramIdentity.maxHashBytes + 1)
        try handle.close()
        let id = try XCTUnwrap(ProgramIdentity.read(path: url.path, hash: true))
        XCTAssertNil(id.sha256)
        XCTAssertEqual(id.size, ProgramIdentity.maxHashBytes + 1)
        XCTAssertTrue(id.matches(ProgramIdentity.read(path: url.path, hash: true)))
        var touched = id; touched.modified = id.modified.addingTimeInterval(-10)
        XCTAssertFalse(touched.matches(id))
    }

    func testUpdatedAgentCLIOnlyAddsANote() throws {
        let cli = try script("""
        cat > /dev/null
        echo '{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"summary\\":\\"All good\\",\\"report_markdown\\":\\"ok\\"}"}}'
        echo '{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}'
        """)
        var settings = AutomationSettings(); settings.codexPath = cli
        var a = Automation(id: "agent-cli", name: "A", kind: .agent(AgentTask(prompt: "x", workingDirectory: dir.path)), schedule: Schedule(rule: .manual))
        a.recordApprovedPrograms(settings: settings)
        XCTAssertNotNil(a.approvedAgentCLI)
        XCTAssertNil(a.approvedAgentCLI?.sha256, "CLIs are not hashed")
        try store.save(a)
        let engine = RunEngine(store: store, context: RunEngine.Context(settings: settings, baseEnvironment: ["HOME": dir.path], retryDelay: 0.01))
        let same = engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a)
        XCTAssertEqual(same.state, .succeeded, same.error ?? "")
        XCTAssertEqual(same.summary, "All good")

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: cli))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("# updated\n".utf8)); try handle.close()
        let updated = engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a)
        XCTAssertEqual(updated.state, .succeeded, updated.error ?? "")
        XCTAssertEqual(updated.summary, "All good (CLI updated since last run)")
    }

    // MARK: Old files

    func testOldAutomationAndRunFilesDecode() throws {
        let oldAutomation = """
        {"version":1,"id":"old-1","name":"Old","symbol":"gearshape.2","kind":{"script":{"_0":{"executable":"/bin/echo","arguments":[],
        "workingDirectory":"/tmp","environment":{},"secretNames":[]}}},"schedule":{"rule":{"manual":{}},"timeZone":"UTC","anchor":0},
        "policy":{"timeout":60,"retries":0,"catchUp":"skip","alertOnFailure":true,"alertOnSuccess":false,"keepRuns":5},
        "enabled":false,"revision":3,"created":0,"updated":0,"notes":""}
        """
        let a = try AutomationJSON.decoder().decode(Automation.self, from: Data(oldAutomation.utf8))
        XCTAssertEqual(a.revision, 3)
        XCTAssertNil(a.approvedProgram); XCTAssertNil(a.approvedAgentCLI)

        let oldRun = """
        {"id":"20260926T081500Z-3f9a","automationID":"old-1","automationName":"Old","revision":3,"trigger":"schedule","occurrence":0,
        "state":"running","attempt":1,"queued":0,"summary":"","questions":[],"ownerPID":123,"ownerStart":0,"alerted":false}
        """
        let r = try AutomationJSON.decoder().decode(RunRecord.self, from: Data(oldRun.utf8))
        XCTAssertEqual(r.ownerPID, 123)
        XCTAssertNil(r.childPGID); XCTAssertNil(r.childStart)

        // And through the store, as the runner reads them.
        try fm.createDirectory(at: store.root.appendingPathComponent("old-1/runs/\(r.id)"), withIntermediateDirectories: true)
        try Data(oldAutomation.utf8).write(to: store.root.appendingPathComponent("old-1/automation.json"))
        try Data(oldRun.utf8).write(to: store.root.appendingPathComponent("old-1/runs/\(r.id)/run.json"))
        XCTAssertEqual(store.automation(id: "old-1")?.name, "Old")
        XCTAssertEqual(store.run(automationID: "old-1", runID: r.id)?.state, .running)
    }
}

private final class PIDBox: @unchecked Sendable { var pid: pid_t = 0 }
private final class RunBox: @unchecked Sendable { var run: RunRecord? }
