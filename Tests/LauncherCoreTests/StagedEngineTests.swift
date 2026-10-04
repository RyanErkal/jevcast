import XCTest
@testable import LauncherCore

/// The staged report engine against fake programs: which stages run, in what order, with which limits,
/// and what a run leaves on disk. No real CLI, script, or network is used.
final class StagedEngineTests: XCTestCase {
    var dir: URL!
    var store: AutomationStore!
    var fx: StagedFixture!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        fx = try StagedFixture(dir: dir)
    }

    override func tearDownWithError() throws {
        _ = try? FileManager.default.subpathsOfDirectory(atPath: dir.path).forEach { chmod(dir.appendingPathComponent($0).path, 0o700) }
        try? FileManager.default.removeItem(at: dir)
    }

    func automation(fetch: Bool = true, timeout: Int = 300, limits: StageLimits = StageLimits()) throws -> Automation {
        let agent = AgentTask(prompt: "Analyse the bundle.", model: "gpt-6.1-sol", effort: .medium, workingDirectory: dir.path)
        let fetchStage = try FetchStage(agent: AgentTask(prompt: "Fetch worker.", model: "gpt-6.1-sol", effort: .medium, workingDirectory: dir.path),
                                        commandDirectory: dir.path, command: [fx.fetchCommand(), "--bundle-only", "--report-date", "{period_key}"],
                                        outputDirectory: dir.appendingPathComponent("reports").path)
        let task = try StagedTask(preflight: ScriptTask(executable: fx.preflight(), workingDirectory: dir.path),
                                  finish: ScriptTask(executable: fx.finish(), workingDirectory: dir.path),
                                  publish: ScriptTask(executable: fx.publish(), workingDirectory: dir.path),
                                  fetch: fetch ? fetchStage : nil, analyst: agent, claim: "other-client", limits: limits)
        let a = Automation(id: "client-weekly", name: "Other Client Weekly Report", kind: .staged(task), schedule: Schedule(rule: .manual),
                           policy: Policy(timeout: timeout, alertOnSuccess: true))
        try store.save(a)
        return a
    }

    func engine() throws -> RunEngine {
        var settings = AutomationSettings(); settings.codexPath = try fx.codex()
        settings.scriptPath = "/usr/bin:/bin"
        var ctx = RunEngine.Context(settings: settings, baseEnvironment: ["HOME": dir.path], retryDelay: 0.01)
        ctx.killGrace = 1
        ctx.toolExecutable = "/usr/bin/true"
        return RunEngine(store: store, context: ctx)
    }

    func run(_ a: Automation) throws -> RunRecord {
        try engine().execute(RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil), automation: a)
    }

    func handoff(_ text: String) throws { _ = try fx.write("handoff.json", text) }

    // MARK: Gate: no model when nothing needs one

    func testNoDueRunsNoAgentAndStaysQuiet() throws {
        let a = try automation()
        try handoff(StagedFixture.handoff("no_due", summary: "Other Client check succeeded. No reports due.", markdown: "No reports due."))
        let r = try run(a)
        XCTAssertEqual(r.state, .succeeded, r.error ?? "")
        XCTAssertEqual(r.quiet, true)
        XCTAssertEqual(r.summary, "Other Client check succeeded. No reports due.")
        XCTAssertEqual(store.readOutput(r), "No reports due.")
        XCTAssertTrue(fx.codexCalls().isEmpty, "no model on a no-due check")
        XCTAssertFalse(AlertDecision.wants(r, policy: a.policy), "a quiet check never alerts")
        XCTAssertNil(StagedClaims(store: store).read("other-client"), "the claim is released")
        let args = try String(contentsOf: dir.appendingPathComponent("preflight-args.txt"), encoding: .utf8)
        XCTAssertTrue(args.hasPrefix("--work-dir " + store.stagingRoot.path), args)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingRoot.appendingPathComponent("client-weekly/\(r.id)").path), "staging is removed")
    }

    func testSavedValidatedReportIsShownWithoutAgent() throws {
        let a = try automation()
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("present_saved", hashes: ["/reports/2026-09-26.md": String(repeating: "b", count: 64)])]))
        let r = try run(a)
        XCTAssertEqual(r.state, .succeeded, r.error ?? "")
        XCTAssertNotEqual(r.quiet, true)
        XCTAssertEqual(r.summary, "Report ready: Other Client weekly 2026-09-26")
        XCTAssertTrue(fx.codexCalls().isEmpty)
        XCTAssertTrue(store.readOutput(r)?.contains("Saved report text") == true)
        let record = try XCTUnwrap(engine().publicationRecord(automationID: a.id, runID: r.id))
        XCTAssertEqual(record.items.map(\.state), [.pending])
        XCTAssertTrue(AlertDecision.wants(r, policy: a.policy), "a ready report alerts when the automation alerts on success")
    }

    func testUntrackedSavedReportIsAdoptedByFinishWithoutAgent() throws {
        let a = try automation()
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("adopt_saved")]))
        let r = try run(a)
        XCTAssertEqual(r.state, .succeeded, r.error ?? "")
        XCTAssertTrue(fx.codexCalls().isEmpty, "zero agents for a saved report")
        let finish = try String(contentsOf: dir.appendingPathComponent("finish-calls.jsonl"), encoding: .utf8)
        XCTAssertTrue(finish.contains("--adopt") && !finish.contains("--agent-output"))
    }

    // MARK: Exact roles, in order

    func testGenerateRunsOneFetchWorkerThenOneAnalyst() throws {
        let a = try automation()
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate", fetch: true)]))
        let r = try run(a)
        XCTAssertEqual(r.state, .succeeded, r.error ?? "")
        let calls = fx.codexCalls()
        XCTAssertEqual(calls.count, 2, "exactly one fetch worker and one analyst")
        let fetch = calls[0].args.joined(separator: " "), analyst = calls[1].args.joined(separator: " ")
        XCTAssertTrue(fetch.contains("mcp_servers.jevfetch.command=\"/usr/bin/true\""))
        XCTAssertTrue(fetch.contains("features.shell_tool=false") && fetch.contains("-s read-only") && !fetch.contains("network_access"))
        XCTAssertTrue(fetch.contains("-m gpt-6.1-sol") && fetch.contains("model_reasoning_effort=\"medium\"") && fetch.contains("--ephemeral"))
        XCTAssertTrue(calls[0].cwd.hasSuffix("/AutomationStaging/client-weekly/" + r.id), "the worker works in its own staging folder: \(calls[0].cwd)")
        XCTAssertFalse(analyst.contains("mcp_servers"), "the analyst has no fetch tool")
        XCTAssertTrue(analyst.contains("-s read-only") && analyst.contains("web_search=\"disabled\"") && !analyst.contains("network_access"))
        XCTAssertTrue(analyst.contains("features.multi_agent=false") && analyst.contains("features.multi_agent_v2=false"))
        // The command ran with exactly the approved arguments and the planner's period.
        let commandArgs = try String(contentsOf: dir.appendingPathComponent("fetch-command-args.txt"), encoding: .utf8)
        XCTAssertEqual(commandArgs.trimmingCharacters(in: .whitespacesAndNewlines), "--bundle-only --report-date 2026-09-26")
        // The analyst saw the planner's data and the command's own manifest.
        let prompt = try String(contentsOf: dir.appendingPathComponent("analyst-prompt.txt"), encoding: .utf8)
        XCTAssertTrue(prompt.contains("Bundle path: /reports/2026-09-26.json") && prompt.contains("READY_FOR_ANALYSIS"))
        // The analyst's answer was saved before finish read it.
        let names = store.runFileNames(automationID: a.id, runID: r.id)
        XCTAssertTrue(names.contains("item1-analyst-output.json") && names.contains("item1-fetch-result.json") && names.contains("stages.json"))
        let stages = try XCTUnwrap(store.readRunFile(automationID: a.id, runID: r.id, name: "stages.json"))
        let order = try JSONDecoder.iso().decode([RunEngine.StageEntry].self, from: stages).map(\.stage)
        XCTAssertEqual(order, ["preflight", "fetch", "analyst", "finish"])
        XCTAssertEqual(r.summary, "Report ready: Weekly 2026-09-26")
    }

    /// Item 1 was saved earlier (present: no stage is logged); item 2 is generated now. The log then holds only
    /// item 2's stages, so a position counted from it would call item 2 the first. Progress shows the stage alone.
    func testMixedSavedAndNewItemsShowOnlyTheLastFinishedStage() throws {
        let a = try automation()
        let saved = StagedFixture.item("present_saved", period: "2026-09-19", hashes: ["/reports/2026-09-19.md": String(repeating: "b", count: 64)])
        let fresh = StagedFixture.item("generate", fetch: true)
        try handoff(StagedFixture.handoff("work", items: [saved, fresh]))
        let r = try run(a)
        let data = try XCTUnwrap(store.readRunFile(automationID: a.id, runID: r.id, name: RunEngine.stagesFile))
        let entries = try JSONDecoder.iso().decode([RunEngine.StageEntry].self, from: data)
        XCTAssertEqual(entries.map(\.stage), ["preflight", "fetch", "analyst", "finish"], "the saved item logs no stage")
        XCTAssertEqual(Set(entries.compactMap(\.item)), [fresh["id"] as? String], "every logged stage belongs to item 2")
        XCTAssertEqual(StageProgress.parse(data), StageProgress(phrase: "Report checked"))
        XCTAssertFalse(StageProgress.parse(data)?.phrase.contains { $0.isNumber } ?? true, "no item position is inferred")
    }

    func testFetchCommandFailureStopsBeforeAnalyst() throws {
        let a = try automation()
        try fx.mode("command-fail")
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate", fetch: true)]))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("The fetch command failed") == true && r.error?.contains("Meta API error 190") == true, r.error ?? "")
        XCTAssertEqual(fx.codexCalls().count, 1, "no analyst after a failed fetch")
    }

    func testWorkerFailureAfterItsCommandStopsAndKeepsData() throws {
        let a = try automation()
        try fx.mode("fetch-turn-fail")
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate", fetch: true)]))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("kept for the next run") == true, r.error ?? "")
        XCTAssertEqual(fx.codexCalls().count, 1)
    }

    func testWorkerThatNeverCallsItsToolFails() throws {
        let a = try automation()
        try fx.mode("fetch-no-call")
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate", fetch: true)]))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("did not run the approved command") == true, r.error ?? "")
    }

    func testWorkerShellUseVoidsTheFetch() throws {
        let a = try automation()
        try fx.mode("fetch-ran-shell")
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate", fetch: true)]))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("shell was off") == true, r.error ?? "")
    }

    /// Defence in depth: the worker's own record must show one call to its one tool and nothing else.
    func testWorkerOtherToolUseOrSecondCallVoidsTheFetch() throws {
        for mode in ["fetch-other-tool", "fetch-called-twice"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("mode-fetch-other-tool"))
            let a = try automation()
            try fx.mode(mode)
            try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate", fetch: true)]))
            let r = try run(a)
            XCTAssertEqual(r.state, .failed, mode)
            XCTAssertTrue(r.error?.contains("exactly one call to its one tool") == true, r.error ?? "")
        }
    }

    func testAnalystFailureStopsTheItem() throws {
        let a = try automation(fetch: false)
        try fx.mode("analyst-fail")
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate")]))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("analyst could not finish") == true, r.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("finish-calls.jsonl").path), "finish never runs")
    }

    func testFetchRequestWithoutFetchStageFails() throws {
        let a = try automation(fetch: false)
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate", fetch: true)]))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(fx.codexCalls().isEmpty)
    }

    // MARK: Stage errors, exit codes, and limits

    func testNonZeroPreflightNeverCountsAsSuccess() throws {
        let a = try automation()
        try handoff(StagedFixture.handoff("no_due"))
        _ = try fx.write("preflight-exit", "1")
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("The preflight failed") == true, r.error ?? "")

        try handoff(StagedFixture.handoff("blocked", summary: "Required source meta failed: token expired. Last success 2026-10-02T08:00:00Z."))
        let blocked = try run(a)
        XCTAssertEqual(blocked.state, .failed)
        XCTAssertEqual(blocked.error, "Required source meta failed: token expired. Last success 2026-10-02T08:00:00Z.")
    }

    func testFinishBlockedIsAFailureWithItsExplanation() throws {
        let a = try automation(fetch: false)
        try fx.mode("finish-blocked")
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate")]))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.error, "Validation failed")
        XCTAssertTrue(store.readOutput(r)?.contains("Missing SMS draft.") == true)
    }

    func testPreflightStageTimeLimit() throws {
        let a = try automation(limits: StageLimits(preflight: 10))
        try fx.mode("preflight-sleep")
        try handoff(StagedFixture.handoff("no_due"))
        let start = Date()
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.error, "The preflight stage stopped after 10 seconds.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 25)
    }

    func testReviewItemStopsWithoutAnyStage() throws {
        let a = try automation()
        var item = StagedFixture.item("review"); item["display"] = "The report changed after its completed receipt."
        try handoff(StagedFixture.handoff("work", items: [item]))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.hasPrefix("Needs review") == true)
        XCTAssertTrue(r.needsReview, "the engine's own review marker")
        XCTAssertTrue(fx.codexCalls().isEmpty)
    }

    /// A planner's own words never become a trusted marker; only the engine writes one.
    func testPlannerTextCannotSetAMarker() throws {
        let a = try automation()
        try handoff(StagedFixture.handoff("blocked", summary: "Needs review: planner text"))
        let blocked = try run(a)
        XCTAssertEqual(blocked.state, .failed)
        XCTAssertFalse(blocked.needsReview)
        try handoff(StagedFixture.handoff("no_due", summary: "Report ready: nothing"))
        let quiet = try run(a)
        XCTAssertEqual(quiet.state, .succeeded, quiet.error ?? "")
        XCTAssertFalse(quiet.hasReadyReport)
    }

    func testOutputWriteFailureFailsClosed() throws {
        let a = try automation()
        let id = RunID.make()
        _ = try fx.write("block-output", store.runFolder(automationID: a.id, runID: id).path)
        try handoff(StagedFixture.handoff("no_due"))
        let r = try engine().execute(RunRecord(id: id, automation: a, trigger: .schedule, occurrence: nil), automation: a)
        XCTAssertEqual(r.state, .failed, "no success without durable output")
        XCTAssertEqual(r.error, "The run's output could not be saved.")
        XCTAssertEqual(store.run(automationID: a.id, runID: id)?.state, .failed)
    }

    func testChangedScriptFileIsRefused() throws {
        var a = try automation(fetch: false)
        let script = try fx.write("planner.ts", "// v1")
        guard case .staged(var t) = a.kind else { return XCTFail() }
        t.preflight.arguments = [script]; a.kind = .staged(t)
        a.recordApprovedPrograms(settings: AutomationSettings())
        XCTAssertTrue(a.approvedFiles?.contains { $0.path == script } == true)
        try store.save(a)
        _ = try fx.write("planner.ts", "// v2")
        try handoff(StagedFixture.handoff("no_due"))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("planner.ts changed") == true, r.error ?? "")
    }

    // MARK: Claims and leftovers

    func testLiveClaimBlocksASecondRun() throws {
        let a = try automation()
        try handoff(StagedFixture.handoff("no_due"))
        var other = RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil)
        other.state = .running
        try store.saveRun(other)
        XCTAssertEqual(StagedClaims(store: store).acquire("other-client", run: other, pid: getpid(), start: Date()), .acquired)
        let r = try run(a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.hasPrefix("Not started.") == true, r.error ?? "")
        XCTAssertNotNil(StagedClaims(store: store).read("other-client"), "the other run keeps its claim")
    }

    func testClaimOfCrashedRunWithUnknownFetchGroupStaysHeld() throws {
        let a = try automation()
        var crashed = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
        crashed.state = .interrupted; crashed.finished = Date()
        try store.saveRun(crashed)
        let group = try OrphanFixture.leaderlessGroup()
        defer { kill(-group, SIGKILL) }
        try store.writeRunFile(automationID: a.id, runID: crashed.id, name: "item1-fetch-child.json",
                               data: AutomationJSON.encoder().encode(FetchToolChild(pgid: group, start: Date())))
        // Even a finished result does not prove the group ended.
        try store.writeRunFile(automationID: a.id, runID: crashed.id, name: "item1-fetch-result.json",
                               data: AutomationJSON.encoder().encode(FetchToolResult(state: "finished", periodKey: "2026-09-26", argv: [], exitCode: 0,
                                                                                     reason: "cancelled", stdout: "", stderr: "", started: Date(), finished: Date())))
        let claims = StagedClaims(store: store)
        XCTAssertEqual(claims.acquire("other-client", run: crashed, pid: 999_999, start: Date.distantPast), .acquired)
        XCTAssertTrue(StagedRecovery.mayRun(store: store, run: crashed))
        let next = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
        guard case .held = claims.acquire("other-client", run: next, pid: getpid(), start: Date()) else { return XCTFail("an unknown group keeps the claim") }
        XCTAssertNotNil(StagedRecovery.stopFetchChildren(store: store, run: crashed, grace: 1), "an unknown group is reported, not stopped")
        XCTAssertEqual(kill(-group, 0), 0, "and it was not signalled")
        kill(-group, SIGKILL)
        for _ in 0..<40 where ProcessInfoReader.groupExists(group) { usleep(50_000) }
        XCTAssertFalse(StagedRecovery.mayRun(store: store, run: crashed))
        XCTAssertEqual(claims.acquire("other-client", run: next, pid: getpid(), start: Date()), .acquired, "taken over once the group is gone")
    }

    /// An unreadable record, or one naming group 0 or 1, is never checked as a group (0 is the caller's own).
    /// It still blocks, with a reason that names the file and how to clear it, and clears once the file is gone.
    func testUnreadableFetchRecordBlocksWithAReasonAndNeverChecksGroupZero() throws {
        XCTAssertEqual(OrphanRecovery.groupState(pgid: 0, start: nil), .gone)
        XCTAssertEqual(OrphanRecovery.groupState(pgid: -1, start: Date()), .gone)
        let a = try automation()
        var crashed = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
        crashed.state = .interrupted; crashed.finished = Date()
        try store.saveRun(crashed)
        let claims = StagedClaims(store: store)
        XCTAssertEqual(claims.acquire("other-client", run: crashed, pid: 999_999, start: Date.distantPast), .acquired)
        let next = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
        for content in [Data("{".utf8), try AutomationJSON.encoder().encode(FetchToolChild(pgid: 0, start: nil))] {
            try store.writeRunFile(automationID: a.id, runID: crashed.id, name: "item1-fetch-child.json", data: content)
            XCTAssertEqual(StagedRecovery.fetchRecords(store: store, run: crashed).map(\.child), [nil])
            let reason = try XCTUnwrap(StagedRecovery.blockReason(store: store, run: crashed))
            XCTAssertTrue(reason.contains("item1-fetch-child.json") && reason.contains("move that file to the Trash"), reason)
            XCTAssertTrue(StagedRecovery.mayRun(store: store, run: crashed))
            XCTAssertEqual(claims.acquire("other-client", run: next, pid: getpid(), start: Date()), .held(reason))
        }
        try FileManager.default.removeItem(at: store.runFolder(automationID: a.id, runID: crashed.id).appendingPathComponent("item1-fetch-child.json"))
        XCTAssertNil(StagedRecovery.blockReason(store: store, run: crashed))
        XCTAssertEqual(claims.acquire("other-client", run: next, pid: getpid(), start: Date()), .acquired, "cleared once the file is gone")
    }

    func testUnconfirmedFetchGroupKeepsTheClaimAndBlocks() throws {
        let a = try automation()
        try fx.mode("fetch-leave-group")
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("generate", fetch: true)]))
        let r = try run(a)
        let group = pid_t(try String(contentsOf: dir.appendingPathComponent("left-group"), encoding: .utf8)) ?? 0
        defer { kill(-group, SIGKILL) }
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("could not be confirmed stopped") == true, r.error ?? "")
        XCTAssertEqual(r.orphanPGID, group)
        XCTAssertEqual(kill(-group, 0), 0, "an unconfirmed group is never signalled")
        XCTAssertEqual(StagedClaims(store: store).read("other-client")?.runID, r.id, "the claim stays with the run")
        XCTAssertTrue(StagedRecovery.mayRun(store: store, run: r))
        XCTAssertEqual(fx.codexCalls().count, 1, "no analyst")
        let next = try run(a)
        XCTAssertTrue(next.error?.hasPrefix("Not started.") == true, next.error ?? "")
    }

    func testStageStderrIsKeptRedactedInTheRunFolder() throws {
        let a = try automation()
        try handoff(StagedFixture.handoff("no_due"))
        let r = try run(a)
        let text = try XCTUnwrap(store.readRunFile(automationID: a.id, runID: r.id, name: "preflight-stderr.txt"))
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "collector warning: lifecycle source slow\n")
    }

    // MARK: Presentation and posting receipts

    func testPublishFailureFailsTheRunAndKeepsTheProof() throws {
        let a = try automation()
        var prior = RunRecord(id: RunID.make(at: Date().addingTimeInterval(-3600)), automation: a, trigger: .schedule, occurrence: nil)
        prior.state = .succeeded; prior.finished = Date().addingTimeInterval(-3500)
        try store.saveRun(prior)
        let item = PublicationItem(job: "other-client:weekly", periodKey: "2026-09-26", title: "Weekly 2026-09-26",
                                   artifactHashes: ["/reports/2026-09-26.md": String(repeating: "c", count: 64)])
        try store.writeRunFile(automationID: a.id, runID: prior.id, name: PublicationRecord.fileName,
                               data: JSONEncoder().encode(PublicationRecord(automationID: a.id, runID: prior.id, items: [item])))
        let proof = PresentationProof(automationID: a.id, runID: prior.id, alertID: "run:\(a.id)/\(prior.id)", presentedAt: Date(), items: [item])
        try store.writeRunFile(automationID: a.id, runID: prior.id, name: PresentationProof.fileName, data: PresentationProof.encoder().encode(proof))
        try fx.mode("publish-fail")
        try handoff(StagedFixture.handoff("no_due"))
        let r = try run(a)
        XCTAssertEqual(r.state, .failed, "a receipt that could not be recorded is not a quiet success")
        XCTAssertTrue(r.error?.contains("could not be recorded") == true, r.error ?? "")
        XCTAssertEqual(try engine().publicationRecord(automationID: a.id, runID: prior.id)?.items.map(\.state), [.pending])
        XCTAssertNotNil(try store.readRunFile(automationID: a.id, runID: prior.id, name: PresentationProof.fileName))
    }

    func testPruneKeepsEvidenceAndLetsSupersededOffersGo() throws {
        let a = try automation()
        var a2 = a; a2.policy.keepRuns = 1; try store.save(a2)
        func finished(_ offset: TimeInterval) throws -> RunRecord {
            var r = RunRecord(id: RunID.make(at: Date().addingTimeInterval(offset)), automation: a2, trigger: .schedule, occurrence: nil)
            r.state = .succeeded; r.finished = Date().addingTimeInterval(offset); try store.saveRun(r); return r
        }
        func offer(_ r: RunRecord, _ period: String, state: PublicationItem.State = .pending) throws {
            let item = PublicationItem(job: "other-client:weekly", periodKey: period, title: period,
                                       artifactHashes: ["/r/\(period).md": String(repeating: "f", count: 64)], state: state)
            try store.writeRunFile(automationID: a.id, runID: r.id, name: PublicationRecord.fileName,
                                   data: JSONEncoder().encode(PublicationRecord(automationID: a.id, runID: r.id, items: [item])))
        }
        let shown = try finished(-500); try offer(shown, "2026-09-12")
        let proof = PresentationProof(automationID: a.id, runID: shown.id, alertID: "x", presentedAt: Date(), items: [])
        try store.writeRunFile(automationID: a.id, runID: shown.id, name: PresentationProof.fileName, data: PresentationProof.encoder().encode(proof))
        let superseded = try finished(-400); try offer(superseded, "2026-09-19")
        let unique = try finished(-300); try offer(unique, "2026-09-05")
        let recorded = try finished(-250); try offer(recorded, "2026-08-29", state: .recorded)
        let group = try OrphanFixture.leaderlessGroup(); defer { kill(-group, SIGKILL) }
        let leftover = try finished(-200)
        try store.writeRunFile(automationID: a.id, runID: leftover.id, name: "item1-fetch-child.json",
                               data: AutomationJSON.encoder().encode(FetchToolChild(pgid: group, start: Date())))
        let newest = try finished(-100); try offer(newest, "2026-09-19")
        store.prune(now: Date(), settings: AutomationSettings())
        let left = Set(store.runs(for: a.id, limit: 100).map(\.id))
        XCTAssertTrue(left.contains(shown.id), "a shown report waits for its receipt")
        XCTAssertFalse(left.contains(superseded.id), "a newer run offers the same report")
        XCTAssertTrue(left.contains(unique.id), "the only offer of a report stays")
        XCTAssertFalse(left.contains(recorded.id), "a recorded offer is done")
        XCTAssertTrue(left.contains(leftover.id), "a program that may still run keeps its record")
        XCTAssertTrue(left.contains(newest.id))
    }

    func testProofFromEarlierRunIsRecordedThroughPublish() throws {
        let a = try automation()
        var prior = RunRecord(id: RunID.make(at: Date().addingTimeInterval(-3600)), automation: a, trigger: .schedule, occurrence: nil)
        prior.state = .succeeded; prior.finished = Date().addingTimeInterval(-3500)
        try store.saveRun(prior)
        let item = PublicationItem(job: "other-client:weekly", periodKey: "2026-09-26", title: "Weekly 2026-09-26",
                                   artifactHashes: ["/reports/2026-09-26.md": String(repeating: "c", count: 64)])
        try store.writeRunFile(automationID: a.id, runID: prior.id, name: PublicationRecord.fileName,
                               data: JSONEncoder().encode(PublicationRecord(automationID: a.id, runID: prior.id, items: [item])))
        // No proof yet: nothing is published.
        try handoff(StagedFixture.handoff("no_due"))
        _ = try run(a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("publish-calls.jsonl").path), "a queued card is not delivery")
        let proof = PresentationProof(automationID: a.id, runID: prior.id, alertID: "run:\(a.id)/\(prior.id)", presentedAt: Date(), items: [item])
        try store.writeRunFile(automationID: a.id, runID: prior.id, name: PresentationProof.fileName, data: PresentationProof.encoder().encode(proof))
        let r = try run(a)
        XCTAssertEqual(r.state, .succeeded, r.error ?? "")
        let calls = try String(contentsOf: dir.appendingPathComponent("publish-calls.jsonl"), encoding: .utf8)
        XCTAssertTrue(calls.contains("--proof") && calls.contains(prior.id))
        XCTAssertEqual(try engine().publicationRecord(automationID: a.id, runID: prior.id)?.items.map(\.state), [.recorded])
        XCTAssertTrue(store.readOutput(r)?.contains("Recorded the posting receipt for Weekly 2026-09-26") == true)
        // Recorded once: a later run does not publish it again.
        _ = try run(a)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("publish-calls.jsonl"), encoding: .utf8).split(separator: "\n").count, 1)
    }

    func testSavedReportWaitingInAnEarlierRunIsNotShownTwice() throws {
        let a = try automation()
        let hashes = ["/reports/2026-09-26.md": String(repeating: "d", count: 64)]
        var prior = RunRecord(id: RunID.make(at: Date().addingTimeInterval(-60)), automation: a, trigger: .schedule, occurrence: nil)
        prior.state = .succeeded; prior.finished = Date().addingTimeInterval(-30)
        try store.saveRun(prior)
        let item = PublicationItem(job: "other-client:weekly", periodKey: "2026-09-26", title: "Other Client weekly 2026-09-26", artifactHashes: hashes)
        try store.writeRunFile(automationID: a.id, runID: prior.id, name: PublicationRecord.fileName,
                               data: JSONEncoder().encode(PublicationRecord(automationID: a.id, runID: prior.id, items: [item])))
        try handoff(StagedFixture.handoff("work", items: [StagedFixture.item("present_saved", hashes: hashes)]))
        let r = try run(a)
        XCTAssertEqual(r.state, .succeeded)
        XCTAssertEqual(r.quiet, true)
        XCTAssertTrue(store.readOutput(r)?.contains("Already waiting to be shown from run \(prior.id)") == true)
        XCTAssertNil(try engine().publicationRecord(automationID: a.id, runID: r.id))
    }
}

extension JSONDecoder {
    static func iso() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// Process groups for orphan tests.
enum OrphanFixture {
    /// A group whose leader has exited while one member (`sleep`) still runs. Returns the group ID.
    static func leaderlessGroup() throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        var pid: pid_t = 0
        let words: [String] = ["/bin/sh", "-c", "sleep 30 & exit 0"]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        guard posix_spawn(&pid, "/bin/sh", nil, &attr, argv, nil) == 0 else { throw NSError(domain: "spawn", code: 1) }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        usleep(100_000)
        return pid
    }
}
