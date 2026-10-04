import XCTest
@testable import LauncherCore

/// The fetch tool server, orphan groups, handoff checks, the setup tool, sign-in checks, and script output.
final class AutomationPortTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("port-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func script(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    // MARK: Fetch tool server

    func spec(command: String, childFile: String? = nil) -> FetchToolSpec {
        FetchToolSpec(periodKey: "2026-09-26", executable: command, arguments: ["--bundle-only", "--report-date", "2026-09-26"],
                      workingDirectory: dir.path, environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path], timeout: 20,
                      resultFile: dir.appendingPathComponent("result.json").path,
                      childFile: childFile ?? dir.appendingPathComponent("child.json").path)
    }

    /// Sends JSON-RPC lines to a server and returns its replies by id. Like Codex, it keeps the server's
    /// input open until every request has its reply; closing it early means the client is gone.
    func exchange(_ server: FetchToolServer, _ lines: [String]) throws -> [Int: [String: Any]] {
        let input = Pipe(), output = Pipe()
        let done = expectation(description: "served")
        DispatchQueue.global().async { server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting); done.fulfill() }
        let expected = lines.filter { $0.contains(#""id":"#) }.count
        for line in lines { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }
        var replies: [Int: [String: Any]] = [:]
        var buffer = Data()
        let deadline = Date().addingTimeInterval(30)
        while replies.count < expected, Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<nl]; buffer = Data(buffer[buffer.index(after: nl)...])
                if let o = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = o["id"] as? Int { replies[id] = o }
            }
        }
        try input.fileHandleForWriting.close()
        wait(for: [done], timeout: 30)
        return replies
    }

    func text(_ reply: [String: Any]?) -> (String, Bool) {
        let result = reply?["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (content, result?["isError"] as? Bool ?? false)
    }

    func testFetchToolRunsItsOneCommandOnceAndRecordsIt() throws {
        let command = try script("fetch", #"echo "$@" > "$HOME/args.txt"; echo '{"status":"READY_FOR_ANALYSIS"}'"#)
        let server = FetchToolServer(spec: spec(command: command))
        let replies = try exchange(server, [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fetch_report_bundle","arguments":{}}}"#,
        ])
        XCTAssertEqual((replies[1]?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        let tools = ((replies[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["fetch_report_bundle"])
        XCTAssertEqual((tools.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, false, "it writes a bundle, so it never claims read only")
        let (out, failed) = text(replies[3])
        XCTAssertFalse(failed, out)
        XCTAssertTrue(out.contains("READY_FOR_ANALYSIS"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8), "--bundle-only --report-date 2026-09-26\n")
        let result = try AutomationJSON.decoder().decode(FetchToolResult.self, from: Data(contentsOf: dir.appendingPathComponent("result.json")))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.argv, [command, "--bundle-only", "--report-date", "2026-09-26"])
        let child = try AutomationJSON.decoder().decode(FetchToolChild.self, from: Data(contentsOf: dir.appendingPathComponent("child.json")))
        XCTAssertGreaterThan(child.pgid, 1)
        XCTAssertNotNil(child.start)

        // A second call, also from a new server process, finds the record and does not run again.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("args.txt"))
        let again = try exchange(FetchToolServer(spec: spec(command: command)), [
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fetch_report_bundle","arguments":{}}}"#,
        ])
        XCTAssertTrue(text(again[4]).1)
        XCTAssertTrue(text(again[4]).0.contains("runs once"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("args.txt").path))
    }

    func testFetchToolRefusesInputAndOtherTools() throws {
        let command = try script("fetch", "touch \"$HOME/ran\"")
        let replies = try exchange(FetchToolServer(spec: spec(command: command)), [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fetch_report_bundle","arguments":{"report_date":"2026-01-03"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shell","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#,
        ])
        XCTAssertTrue(text(replies[1]).1)
        XCTAssertTrue(text(replies[2]).1)
        XCTAssertNotNil(replies[3]?["error"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ran").path), "the period comes from the spec, never from input")
    }

    func testFetchToolStopsWhenItCannotSaveTheChildIdentity() throws {
        let command = try script("fetch", "sleep 20; touch \"$HOME/finished\"")
        let missing = dir.appendingPathComponent("no-such-folder/child.json").path
        let replies = try exchange(FetchToolServer(spec: spec(command: command, childFile: missing)), [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fetch_report_bundle","arguments":{}}}"#,
        ])
        let (out, failed) = text(replies[1])
        XCTAssertTrue(failed)
        XCTAssertTrue(out.contains("identity could not be saved"), out)
        let result = try AutomationJSON.decoder().decode(FetchToolResult.self, from: Data(contentsOf: dir.appendingPathComponent("result.json")))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.reason, "identityNotSaved", "without an identity the result never counts")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("finished").path))
    }

    func testFetchToolSpecMustBeOwnedAndValid() throws {
        let url = dir.appendingPathComponent("spec.json")
        var s = spec(command: "/bin/echo"); s.periodKey = "2026-13-01"
        try AutomationJSON.encoder().encode(s).write(to: url)
        XCTAssertNil(FetchToolServer.loadSpec(url.path))
        s.periodKey = "2026-09-26"
        try AutomationJSON.encoder().encode(s).write(to: url)
        XCTAssertNotNil(FetchToolServer.loadSpec(url.path))
    }

    // MARK: Orphan groups

    func testLeaderlessGroupIsUnknownNeverSignalledAndBlocks() throws {
        let group = try OrphanFixture.leaderlessGroup()
        defer { kill(-group, SIGKILL) }
        XCTAssertEqual(OrphanRecovery.groupState(pgid: group, start: Date()), .unknown)
        let a = Automation(id: "orphan-1", name: "O", kind: .script(ScriptTask(executable: "/bin/echo", workingDirectory: "/")), schedule: Schedule(rule: .manual))
        var run = RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil)
        run.state = .running; run.childPGID = group; run.childStart = Date()
        XCTAssertEqual(OrphanRecovery.stopChild(of: run, grace: 1), .unconfirmed)
        XCTAssertEqual(kill(-group, 0), 0, "an unknown group is not signalled")
        let interrupted = OrphanRecovery.interrupt(run, grace: 1)
        XCTAssertEqual(interrupted.orphanPGID, group, "its identity is kept")
        XCTAssertNil(OrphanRecovery.resolvedOrphan(interrupted), "it still may run")
        // No recorded start time: also unknown, also left alone.
        run.childStart = nil
        XCTAssertEqual(OrphanRecovery.stopChild(of: run, grace: 1), .unconfirmed)
        kill(-group, SIGKILL)
        for _ in 0..<40 where ProcessInfoReader.groupExists(group) { usleep(50_000) }
        XCTAssertEqual(OrphanRecovery.groupState(pgid: group, start: Date()), .gone)
        XCTAssertNotNil(OrphanRecovery.resolvedOrphan(interrupted), "cleared once the group is gone")
    }

    // MARK: Handoff

    func testHandoffRejectsWrongTypesAndBadPeriods() {
        func parse(_ json: String) -> Error? {
            do { _ = try StagedHandoff.parse(Data(json.utf8)); return nil } catch { return error }
        }
        let item = #""id":"other-client:weekly:2026-09-26","job":"other-client:weekly","period_key":"2026-09-26","action":"generate","title":"T""#
        XCTAssertNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":[{\#(item),"fetch":true}]}"#))
        XCTAssertNotNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":"all"}"#), "items must be a list")
        XCTAssertNotNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":[{\#(item),"fetch":"yes"}]}"#), "fetch must be a boolean")
        XCTAssertNotNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":[{\#(item),"fetch":1}]}"#), "a number is not a boolean")
        XCTAssertNotNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":[{\#(item),"artifact_hashes":[]}]}"#))
        XCTAssertNotNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":[{\#(item.replacingOccurrences(of: "2026-09-26\",\"action", with: "2026-02-30\",\"action"))}]}"#))
        XCTAssertNotNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"no_due","summary":"s","items":[{\#(item)}]}"#), "no_due has no items")
        XCTAssertNotNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":[]}"#), "work needs items")
        XCTAssertNotNil(parse(#"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":[{\#(item.replacingOccurrences(of: "generate", with: "present_saved"))}]}"#),
                        "a saved report needs its hashes")
        XCTAssertNotNil(parse(#"{"schema":"other","outcome":"no_due","summary":"s"}"#))
        XCTAssertNotNil(parse(String(repeating: " ", count: StagedHandoff.maxBytes + 1)))
        // Logging before the JSON line is fine.
        XCTAssertNil(parse("collecting...\n" + #"{"schema":"jevcast.staged.v1","outcome":"no_due","summary":"s"}"#))
        XCTAssertTrue(StagedHandoff.isPeriodKey("2026-09"))
        XCTAssertFalse(StagedHandoff.isPeriodKey("2026-9-1"))
    }

    /// The finish script gets the ID as `--item <id>`, so an ID that reads as an option is refused.
    func testHandoffRejectsItemIDsThatStartWithADash() {
        for id in ["--adopt", "-x", "-"] {
            let json = #"{"schema":"jevcast.staged.v1","outcome":"work","summary":"s","items":[{"id":"\#(id)","job":"j","period_key":"2026-09-26","action":"generate","title":"T"}]}"#
            XCTAssertThrowsError(try StagedHandoff.parse(Data(json.utf8)), id) { error in
                XCTAssertTrue("\(error)".contains("starts with \"-\""), "\(error)")
            }
        }
    }

    // MARK: Setup tool

    func setupSpec(model: String = "gpt-6.1-sol", fetchAccess: String = "readOnly") throws -> Data {
        let bun = try script("bun", "exit 0")
        let entry = dir.appendingPathComponent("jevcast-reports.ts"); try "// v1".write(to: entry, atomically: true, encoding: .utf8)
        func agent(_ access: String) -> String {
            #"{"runner":"codex","prompt":"Read only.","model":"\#(model)","effort":"medium","fast":false,"workingDirectory":"\#(dir.path)","allowedRoots":[],"access":"\#(access)","output":"report"}"#
        }
        func s(_ args: String) -> String {
            #"{"executable":"\#(bun)","arguments":[\#(args)],"workingDirectory":"\#(dir.path)","environment":{},"secretNames":[]}"#
        }
        let policy = #"{"timeout":3600,"retries":0,"catchUp":"runOnce","alertOnFailure":true,"alertOnSuccess":true,"keepRuns":200,"sharedLock":"docs-workspace"}"#
        return Data(#"""
        {"schema":"jevcast.setup.v1","maxConcurrentRuns":1,"automations":[
          {"id":"docs-agents-backup","name":"Docs and Agents Hourly Backup","schedule":{"rrule":"FREQ=DAILY;BYHOUR=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23;BYMINUTE=0","timeZone":"Europe/London"},
           "policy":\#(policy),"script":\#(s(#""jevcast-reports.ts","backup""#)),"diagnosis":\#(agent("readOnly"))},
          {"id":"other-weekly","name":"Other Client Weekly Report","schedule":{"rrule":"FREQ=HOURLY","timeZone":"Europe/London"},
           "policy":\#(policy),"staged":{"preflight":\#(s(#""jevcast-reports.ts","preflight""#)),"finish":\#(s(#""jevcast-reports.ts","finish""#)),
             "publish":\#(s(#""jevcast-reports.ts","publish""#)),"analyst":\#(agent("readOnly")),"claim":"other-client","limits":{"maxItems":1},
             "fetch":{"agent":\#(agent(fetchAccess)),"commandDirectory":"\#(dir.path)","command":["\#(bun)","x.ts","--report-date","{period_key}"],"outputDirectory":"\#(dir.path)"}}},
          {"id":"sample-reports","name":"Sample Client Metrics and Reports","schedule":{"rrule":"FREQ=DAILY;BYHOUR=0,4,8,12,16,20;BYMINUTE=0","timeZone":"Europe/London"},
           "policy":\#(policy),"staged":{"preflight":\#(s(#""jevcast-reports.ts","preflight""#)),"finish":\#(s(#""jevcast-reports.ts","finish""#)),
             "analyst":\#(agent("readOnly")),"claim":"sample-client"}}
        ]}
        """#.utf8)
    }

    func testSetupCreatesPausedDefinitionsAndApprovesScriptFiles() throws {
        let store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        var settings = AutomationSettings(); settings.codexPath = "/bin/echo"; settings.maxConcurrentRuns = 2
        try store.saveSettings(settings)
        let spec = try AutomationSetup.decode(setupSpec())
        let check = AutomationSetup.apply(spec, store: store, check: true)
        XCTAssertTrue(check.problems.isEmpty, "\(check.problems)")
        XCTAssertTrue(store.loadAutomations().automations.isEmpty, "check writes nothing")
        let report = AutomationSetup.apply(spec, store: store, check: false)
        XCTAssertTrue(report.applied, "\(report.problems)")
        XCTAssertEqual(report.changes.map(\.kind), [.created, .created, .created])
        XCTAssertEqual(store.loadSettings().maxConcurrentRuns, 1, "the global cap starts at one")
        let all = store.loadAutomations().automations
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.allSatisfy { !$0.enabled }, "setup never turns anything on")
        let weekly = try XCTUnwrap(store.automation(id: "other-weekly"))
        XCTAssertTrue(weekly.approvedFiles?.contains { $0.path.hasSuffix("jevcast-reports.ts") && $0.sha256 != nil } == true)
        XCTAssertEqual(weekly.policy.sharedLock, "docs-workspace")

        // Unchanged spec: nothing changes. An edited script file: re-approved, same definition.
        XCTAssertEqual(AutomationSetup.apply(spec, store: store, check: false).changes.map(\.kind), [.unchanged, .unchanged, .unchanged])
        try "// v2".write(to: dir.appendingPathComponent("jevcast-reports.ts"), atomically: true, encoding: .utf8)
        var on = weekly; on.enabled = true; try store.save(on)
        let again = AutomationSetup.apply(spec, store: store, check: false)
        XCTAssertEqual(again.changes.first { $0.id == "other-weekly" }?.kind, .reapproved)
        XCTAssertEqual(store.automation(id: "other-weekly")?.enabled, true, "an automation the user turned on stays on")
        XCTAssertEqual(store.automation(id: "other-weekly")?.revision, weekly.revision + 1)
    }

    func testSetupRefusesUnsafeOrVagueDefinitions() throws {
        let store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        var settings = AutomationSettings(); settings.codexPath = "/bin/echo"; try store.saveSettings(settings)
        let noModel = AutomationSetup.apply(try AutomationSetup.decode(setupSpec(model: "")), store: store, check: false)
        XCTAssertFalse(noModel.applied)
        XCTAssertTrue(noModel.problems.contains { $0.contains("exact model") })
        let writer = AutomationSetup.apply(try AutomationSetup.decode(setupSpec(fetchAccess: "workspaceWriteNetwork")), store: store, check: false)
        XCTAssertTrue(writer.problems.contains { $0.contains("fetch worker must be read only") })
        XCTAssertTrue(store.loadAutomations().automations.isEmpty, "a spec with problems writes nothing")
    }

    /// The schedules across the October 2026 change from BST to GMT (Europe/London, 25 Oct 01:00 BST).
    func testSchedulesAcrossClockChange() throws {
        let zone = TimeZone(identifier: "Europe/London")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 22))!
        let anchor = calendar.startOfDay(for: start)
        // Hourly rules take their minute from the anchor, which setup puts at local midnight (:00).
        let hourly = try RRule("FREQ=HOURLY").occurrences(after: start, anchor: anchor, timeZone: zone, limit: 30)
        XCTAssertTrue(hourly.allSatisfy { calendar.component(.minute, from: $0) == 0 })
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        let dayEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let onDay = hourly.filter { $0 >= dayStart && $0 < dayEnd }
        XCTAssertEqual(onDay.count, 25, "the repeated hour runs once for each real hour")
        XCTAssertEqual(Set(onDay).count, onDay.count, "never twice for one instant")
        // The definitions pin hourly jobs to :00 with every hour listed, so no anchor can move them.
        let pinned = try RRule("FREQ=DAILY;BYHOUR=" + (0..<24).map(String.init).joined(separator: ",") + ";BYMINUTE=0")
            .occurrences(after: start, anchor: Date(timeIntervalSince1970: 0), timeZone: zone, limit: 60)
        let pinnedDay = pinned.filter { $0 >= dayStart && $0 < dayEnd }
        XCTAssertTrue(pinned.allSatisfy { calendar.component(.minute, from: $0) == 0 })
        XCTAssertEqual(Set(pinnedDay).count, pinnedDay.count, "never twice for one instant")
        XCTAssertTrue((24...25).contains(pinnedDay.count), "one run for each local hour on the change day: \(pinnedDay.count)")
        let sixHourly = try RRule("FREQ=DAILY;BYHOUR=0,4,8,12,16,20;BYMINUTE=0").occurrences(after: start, anchor: anchor, timeZone: zone, limit: 12)
        let hours = sixHourly.map { calendar.component(.hour, from: $0) }
        XCTAssertEqual(Array(hours.prefix(12)), [0, 4, 8, 12, 16, 20, 0, 4, 8, 12, 16, 20], "local hours stay fixed across the change")
    }

    // MARK: Sign-in

    func testCodexSignInMustBeASubscription() {
        XCTAssertEqual(CodexAuth.status(["tokens": ["access_token": "a", "refresh_token": "r"], "OPENAI_API_KEY": NSNull()]), .subscription)
        if case .subscription = CodexAuth.status(["OPENAI_API_KEY": "sk-live", "tokens": ["access_token": "a"]]) { XCTFail("an API key bills the API") }
        if case .subscription = CodexAuth.status(["auth_mode": "apikey", "tokens": ["access_token": "a"]]) { XCTFail() }
        if case .subscription = CodexAuth.status([:]) { XCTFail("no sign-in") }
        if case .subscription = CodexAuth.check(home: dir.path) { XCTFail("a missing file is not a sign-in") }
    }

    func testAgentRunStopsBeforeStartingWithAnAPIKeySignIn() throws {
        let store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data(#"{"OPENAI_API_KEY":"sk-test-not-real","tokens":null}"#.utf8).write(to: dir.appendingPathComponent(".codex/auth.json"))
        let cli = try script("codex", "touch \"$HOME/started\"")
        var settings = AutomationSettings(); settings.codexPath = cli
        let a = Automation(id: "agent-key", name: "A", kind: .agent(AgentTask(prompt: "x", model: "gpt-6.1-sol", workingDirectory: dir.path)), schedule: Schedule(rule: .manual))
        try store.save(a)
        let r = RunEngine(store: store, context: RunEngine.Context(settings: settings, baseEnvironment: ["HOME": dir.path], retryDelay: 0.01))
            .execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertTrue(r.error?.contains("API key") == true, r.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("started").path), "the CLI never started")
    }

    // MARK: Child identity

    struct SaveFailed: Error {}

    func testChildIsStoppedAndRunFailsWhenItsIdentityCannotBeSaved() throws {
        let store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        for body in ["sleep 20; touch \"$HOME/finished\"", "exit 0"] {
            let a = Automation(id: "identity-\(body.count)", name: "I", kind: .script(ScriptTask(executable: "/bin/sh", arguments: ["-c", body], workingDirectory: dir.path)),
                               schedule: Schedule(rule: .manual))
            try store.save(a)
            var ctx = RunEngine.Context(settings: AutomationSettings(), baseEnvironment: ["HOME": dir.path], retryDelay: 0.01)
            ctx.killGrace = 1
            let engine = RunEngine(store: store, context: ctx)
            engine.saveChildIdentity = { _ in throw SaveFailed() }
            let start = Date()
            let r = engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a)
            XCTAssertEqual(r.state, .failed, "even a child that exits 0 at once does not count: \(body)")
            XCTAssertEqual(r.error, RunEngine.identityNotSaved)
            XCTAssertEqual(r.attempt, 1, "not retried as a start failure")
            XCTAssertNil(r.orphanPGID, "the stopped group is gone, so nothing is kept")
            XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("finished").path), "the long child was stopped")
    }

    // MARK: Scripts, diagnosis, and repeated failures

    func testScriptKeepsRedactedStderrAndAUsefulError() throws {
        let store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        let a = Automation(id: "backup-1", name: "B", kind: .script(ScriptTask(executable: "/bin/sh",
            arguments: ["-c", "echo 'Docs: verified'; echo 'TOKEN=abcdef0123456789' >&2; echo 'Agents: diverged 42 ahead, 42 behind; refusing backup' >&2; exit 1"],
            workingDirectory: dir.path)), schedule: Schedule(rule: .manual))
        try store.save(a)
        let r = RunEngine(store: store, context: RunEngine.Context(settings: AutomationSettings(), baseEnvironment: ["HOME": dir.path], retryDelay: 0.01))
            .execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a)
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.error, "Exited with code 1. Agents: diverged 42 ahead, 42 behind; refusing backup")
        let output = try XCTUnwrap(store.readOutput(r))
        XCTAssertTrue(output.contains("Standard error (last part, redacted)") && output.contains("Docs: verified"))
        XCTAssertFalse(output.contains("abcdef0123456789"), "secrets in stderr are redacted")
    }

    func testDiagnosisRunsAfterTheLastRetryAndNotForTheSameFailureAgain() throws {
        let store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        try TestCodexSignIn.install(home: dir)
        let reply = #"{"summary":"Diverged branch","report_markdown":"The agents repository needs a manual merge."}"#
            .replacingOccurrences(of: "\"", with: "\\\"")
        let cli = try script("codex", """
        cat > /dev/null
        echo "x" >> "$HOME/diagnoses.txt"
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"\(reply)"}}'
        """)
        var settings = AutomationSettings(); settings.codexPath = cli
        let failing = ScriptTask(executable: "/bin/sh", arguments: ["-c", "echo 'push rejected' >&2; exit 1"], workingDirectory: dir.path)
        let a = Automation(id: "diag-retry", name: "D", kind: .scriptWithDiagnosis(failing, AgentTask(prompt: "Why?", model: "gpt-6.1-sol",
                           workingDirectory: dir.path)), schedule: Schedule(rule: .manual), policy: Policy(retries: 1))
        try store.save(a)
        let engine = RunEngine(store: store, context: RunEngine.Context(settings: settings, baseEnvironment: ["HOME": dir.path], retryDelay: 0.01))
        let first = engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a)
        XCTAssertEqual(first.state, .failed)
        XCTAssertEqual(first.attempt, 2)
        XCTAssertTrue(store.readOutput(first)?.contains("needs a manual merge") == true, "the final retry is diagnosed")
        usleep(1_100_000) // a later run ID
        let second = engine.execute(RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil), automation: a)
        XCTAssertTrue(store.readOutput(second)?.contains("no new diagnosis ran") == true)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("diagnoses.txt"), encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertTrue(FailureDedupe.isRepeat(second, previous: first))
        var different = second; different.error = "Exited with code 1. remote hung up"
        XCTAssertFalse(FailureDedupe.isRepeat(different, previous: first), "a new error alerts again")
    }
}

/// Commit IDs stay readable only in their exact labels; every secret rule still applies first.
final class RedactorCommitLabelTests: XCTestCase {
    let sha = "0a32a7a1c4e5f60718293a4b5c6d7e8f90123456"

    func testLabelledFullCommitIDsStayReadable() {
        let text = "- docs: changes committed and pushed. Verified Git commit: \(sha).\nLocal Git commit: \(sha); Remote Git commit: \(sha)"
        XCTAssertEqual(Redactor.redact(text), text)
    }

    func testUnlabelledOrMalformedLongTokensAreMasked() {
        for text in ["commit \(sha)", "Verified Git commit:\(sha)", "verified git commit: \(sha)", "Verified Git commit: \(sha.uppercased())",
                     "Verified Git commit: \(sha)ab", "Verified Git commit: \(sha)=", "Git commit: \(sha)",
                     "Verified Git commit: " + String(repeating: "Ab0", count: 14)] {
            XCTAssertFalse(Redactor.redact(text).contains(sha.prefix(20)) || Redactor.redact(text).contains("Ab0Ab0Ab0Ab0Ab0"), text)
        }
    }

    func testSecretsAndNamedCredentialsAreMaskedFirst() {
        // A known secret that looks like a commit ID is masked even when labelled.
        XCTAssertEqual(Redactor.redact("Verified Git commit: \(sha)", known: [sha]), "Verified Git commit: [redacted]")
        // A named credential assignment is masked, label or not.
        XCTAssertFalse(Redactor.redact("GITHUB_TOKEN=\(sha)").contains(sha))
        XCTAssertFalse(Redactor.redact("api_key: Verified Git commit: \(sha)").contains("Verified Git commit: \(sha)"))
        XCTAssertFalse(Redactor.redact("Authorization: Bearer \(sha)").contains(sha))
        XCTAssertFalse(Redactor.redact("ghp_" + String(repeating: "a", count: 36)).contains("aaaaaaaaaaaaaaaa"))
        XCTAssertFalse(Redactor.redact("sk-" + String(repeating: "b", count: 40)).contains("bbbbbbbbbbbb"))
        XCTAssertFalse(Redactor.redact("token=Verified Git commit: \(sha)").contains("token=Verified"))
    }
}
