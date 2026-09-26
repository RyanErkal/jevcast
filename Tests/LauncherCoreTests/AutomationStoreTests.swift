import XCTest
@testable import LauncherCore

final class AutomationStoreTests: XCTestCase {
    var dir: URL!
    var store: AutomationStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AutomationStore(root: dir.appendingPathComponent("Automations"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func sample(_ id: String = "tidy-1a2b", keep: Int = 50) -> Automation {
        Automation(id: id, name: "Tidy", kind: .script(ScriptTask(executable: "/bin/echo", arguments: ["hi"], workingDirectory: "/tmp")),
                   schedule: Schedule(rule: .rrule("FREQ=DAILY;BYHOUR=4"), timeZone: "Europe/London"), policy: Policy(keepRuns: keep))
    }

    func mode(_ url: URL) throws -> Int {
        ((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as! NSNumber).intValue
    }

    func testSaveLoadAndPermissions() throws {
        let a = sample()
        try store.save(a)
        let loaded = store.loadAutomations()
        XCTAssertEqual(loaded.automations, [a]); XCTAssertTrue(loaded.problems.isEmpty)
        XCTAssertEqual(try mode(store.root), 0o700)
        XCTAssertEqual(try mode(store.root.appendingPathComponent(a.id)), 0o700)
        XCTAssertEqual(try mode(store.root.appendingPathComponent(a.id).appendingPathComponent("automation.json")), 0o600)
    }

    func testProblemsAndInvalidIDs() throws {
        let bad = store.root.appendingPathComponent("broken-1")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad.appendingPathComponent("automation.json"))
        XCTAssertNotNil(store.loadAutomations().problems["broken-1"])
        XCTAssertThrowsError(try store.save(sample("../evil")))
        XCTAssertNil(store.run(automationID: "tidy-1a2b", runID: "../../x"))
        XCTAssertEqual(store.runFolder(automationID: "..", runID: "x").lastPathComponent, "invalid")
    }

    func testRefusesSymlinks() throws {
        let a = sample()
        try store.save(a)
        let target = dir.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: target)
        let link = store.root.appendingPathComponent(a.id).appendingPathComponent("state.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try store.saveState(AutomationState(lastCovered: Date()), for: a.id)) { error in
            XCTAssertEqual(error as? AutomationStoreError, .symlink(link.path))
        }
        XCTAssertEqual(store.state(for: a.id), AutomationState())
        // A symlinked automation folder is skipped.
        let other = dir.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("linked-1"), withDestinationURL: other)
        XCTAssertEqual(store.loadAutomations().automations.map(\.id), [a.id])
    }

    func testRunsNewestFirstAndOutput() throws {
        let a = sample(); try store.save(a)
        var ids: [String] = []
        for i in 0..<3 {
            let run = RunRecord(id: RunID.make(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60)), automation: a, trigger: .manual, occurrence: nil,
                                queued: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60))
            try store.saveRun(run); ids.append(run.id)
        }
        XCTAssertEqual(store.runs(for: a.id, limit: 2).map(\.id), [ids[2], ids[1]])
        XCTAssertEqual(store.allRecentRuns(limit: 10).map(\.id), ids.reversed())
        var run = store.run(automationID: a.id, runID: ids[0])!
        try store.writeRunFile(automationID: a.id, runID: run.id, name: "output.md", data: Data("# Hi".utf8))
        run.outputFile = "output.md"
        XCTAssertEqual(store.readOutput(run), "# Hi")
        run.outputFile = "../automation.json"
        XCTAssertNil(store.readOutput(run))
    }

    func testRequestsSettingsHeartbeatState() throws {
        let r = RunnerRequest(action: .runNow(automationID: "tidy-1a2b", test: true))
        try store.submit(r)
        XCTAssertEqual(store.pendingRequests(), [r])
        store.removeRequest(id: r.id)
        XCTAssertEqual(store.pendingRequests(), [])
        XCTAssertEqual(store.loadSettings(), AutomationSettings())
        var s = AutomationSettings(); s.maxConcurrentRuns = 3
        try store.saveSettings(s); XCTAssertEqual(store.loadSettings(), s)
        let hb = RunnerHeartbeat(pid: 42, started: Date(timeIntervalSince1970: 1), heartbeat: Date(timeIntervalSince1970: 2), version: "1", signedBuild: false)
        try store.writeHeartbeat(hb); XCTAssertEqual(store.readHeartbeat(), hb)
        let a = sample(); try store.save(a)
        let st = AutomationState(lastCovered: Date(timeIntervalSince1970: 1_800_000_000.123), lastRunID: "x")
        try store.saveState(st, for: a.id); XCTAssertEqual(store.state(for: a.id), st)
    }

    func testOversizedFileRefused() throws {
        let a = sample(); try store.save(a)
        try Data(count: 3 * 1024 * 1024).write(to: store.root.appendingPathComponent("settings.json"))
        XCTAssertEqual(store.loadSettings(), AutomationSettings())
    }

    func testPruneKeepsActiveAndWaitingRuns() throws {
        let a = sample(keep: 2); try store.save(a)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ offset: Double, _ state: RunState) throws -> String {
            var run = RunRecord(id: RunID.make(at: now.addingTimeInterval(offset)), automation: a, trigger: .schedule, occurrence: nil,
                                queued: now.addingTimeInterval(offset))
            run.state = state; run.finished = state.isFinished ? run.queued : nil
            try store.saveRun(run); return run.id
        }
        let oldWaiting = try add(-100 * 86400, .needsApproval)
        let oldRunning = try add(-99 * 86400, .running)
        let oldDone = try add(-98 * 86400, .succeeded)
        let a1 = try add(-3000, .failed)
        let a2 = try add(-2000, .succeeded)
        let a3 = try add(-1000, .succeeded)
        let removed = store.prune(now: now, settings: AutomationSettings(historyDays: 30))
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(Set(store.runs(for: a.id, limit: 50).map(\.id)), [oldWaiting, oldRunning, a2, a3])
        _ = (oldDone, a1)
    }

    func testRemoveMovesToTrash() throws {
        // Uses a real Trash only when the folder is on a volume with one; skip otherwise.
        let a = sample(); try store.save(a)
        do { try store.remove(id: a.id) } catch { throw XCTSkip("No Trash for the temp volume: \(error)") }
        XCTAssertTrue(store.loadAutomations().automations.isEmpty)
    }

    func testRemoveFinishedRunsKeepsActiveAndWaiting() throws {
        let a = sample(); try store.save(a)
        var ids: [RunState: String] = [:]
        for (i, state) in [RunState.succeeded, .failed, .needsInput, .running].enumerated() {
            var run = RunRecord(id: RunID.make(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))), automation: a,
                                trigger: .manual, occurrence: nil)
            run.state = state; try store.saveRun(run); ids[state] = run.id
        }
        XCTAssertEqual(store.removeFinishedRuns(), 2)
        XCTAssertEqual(Set(store.runs(for: a.id, limit: 10).map(\.id)), [ids[.needsInput]!, ids[.running]!])
    }

    func testTopFiles() throws {
        struct Item: Codable, Equatable { var name: String }
        XCTAssertNil(store.readTopFile([Item].self, name: "clients.json"))
        XCTAssertFalse(store.hasTopFile("clients.json"))
        try store.writeTopFile([Item(name: "Stein")], name: "clients.json")
        XCTAssertEqual(store.readTopFile([Item].self, name: "clients.json"), [Item(name: "Stein")])
        XCTAssertEqual(try mode(store.root.appendingPathComponent("clients.json")), 0o600)
        XCTAssertThrowsError(try store.writeTopFile(Item(name: "x"), name: "../x.json"))
        XCTAssertThrowsError(try store.writeTopFile(Item(name: "x"), name: "runner.json"))
    }
}
