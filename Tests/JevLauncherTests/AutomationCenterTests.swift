import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class AutomationCenterTests: XCTestCase {
    private var base: URL!
    /// Proposals refuse /private, where the temporary folder lives, so file work happens in a hidden home folder.
    private var workURL: URL!
    private var center: AutomationCenter!
    private let fm = FileManager.default

    override func setUp() async throws {
        base = fm.temporaryDirectory.appendingPathComponent("center-\(UUID().uuidString)")
        workURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".jevcast-test-\(UUID().uuidString)")
        try fm.createDirectory(at: workURL, withIntermediateDirectories: true)
        center = AutomationCenter(isolatedStore: AutomationStore(root: base.appendingPathComponent("Automations")))
    }

    override func tearDown() async throws { try? fm.removeItem(at: base); try? fm.removeItem(at: workURL) }

    private var work: String { workURL.path }

    private func agent(output: OutputMode = .proposal) -> Automation {
        Automation(id: AutomationID.make(from: "Tidy"), name: "Tidy",
                   kind: .agent(AgentTask(prompt: "tidy", workingDirectory: work, output: output)), schedule: Schedule(rule: .manual))
    }

    func testSaveBumpsRevisionExceptNew() {
        let a = agent()
        XCTAssertNil(center.save(a))
        XCTAssertEqual(center.automation(a.id)?.revision, 1)
        var edited = center.automation(a.id)!
        edited.name = "Tidy desk"
        XCTAssertNil(center.save(edited))
        XCTAssertEqual(center.automation(a.id)?.revision, 2)
        XCTAssertEqual(center.store.automation(id: a.id)?.name, "Tidy desk")
    }

    func testEnableRefusedWithoutCLIAndDuplicateIsPaused() {
        let a = agent()
        center.save(a)
        XCTAssertNotNil(center.setEnabled(a.id, true))
        XCTAssertEqual(center.automation(a.id)?.enabled, false)
        let copy = center.duplicate(a.id)
        XCTAssertEqual(copy?.name, "Tidy copy")
        XCTAssertEqual(copy?.enabled, false)
        XCTAssertNotEqual(copy?.id, a.id)
    }

    func testScriptWithMissingFolderCannotTurnOn() {
        let a = Automation(id: "s-1", name: "S", kind: .script(ScriptTask(executable: "/bin/echo", workingDirectory: base.path + "/nope")),
                           schedule: Schedule(rule: .manual))
        center.save(a)
        XCTAssertNotNil(center.setEnabled(a.id, true))
        var ok = a; ok.kind = .script(ScriptTask(executable: "/bin/echo", workingDirectory: work))
        center.save(ok)
        XCTAssertNil(center.setEnabled(a.id, true))
        XCTAssertEqual(center.automation(a.id)?.enabled, true)
    }

    func testApproveAppliesJournalsAndUndoes() throws {
        try Data("x".utf8).write(to: URL(fileURLWithPath: work + "/a.txt"))
        try fm.createDirectory(atPath: work + "/Done", withIntermediateDirectories: false)
        let a = agent()
        center.save(a)
        let saved = center.automation(a.id)!
        var run = RunRecord(id: RunID.make(), automation: saved, trigger: .manual, occurrence: nil)
        run.state = .needsApproval; run.finished = Date()
        try center.store.saveRun(run)
        let raw = try JSONSerialization.data(withJSONObject: ["version": 1, "summary": "s", "items": [
            ["id": "m", "op": "move", "from": work + "/a.txt", "to": work + "/Done/a.txt", "reason": "r"],
            ["id": "d", "op": "trash", "path": work + "/Done", "reason": "folders are refused"]
        ]])
        try center.store.writeRunFile(automationID: a.id, runID: run.id, name: RunEngine.proposalRawFile, data: raw)

        guard case .success(let manifest)? = center.proposal(for: run) else { return XCTFail("no proposal") }
        XCTAssertEqual(manifest.checked.map(\.id), ["m"])
        XCTAssertEqual(manifest.refused["d"], "Folders cannot be moved or trashed yet")

        let journal = try XCTUnwrap(center.approve(run, items: ["m"]))
        XCTAssertEqual(journal.summaryText, "Moved 1")
        XCTAssertTrue(fm.fileExists(atPath: work + "/Done/a.txt"))
        let after = try XCTUnwrap(center.store.run(automationID: a.id, runID: run.id))
        XCTAssertEqual(after.state, .succeeded)
        XCTAssertEqual(after.summary, "Moved 1")
        XCTAssertNotNil(center.journal(for: after))

        _ = center.undo(after)
        XCTAssertTrue(fm.fileExists(atPath: work + "/a.txt"))
        XCTAssertNil(center.approve(after, items: ["m"]), "A finished run cannot be approved again")
    }

    func testExpiredProposalIsRefused() throws {
        try Data("x".utf8).write(to: URL(fileURLWithPath: work + "/a.txt"))
        let a = agent()
        center.save(a)
        var run = RunRecord(id: RunID.make(), automation: center.automation(a.id)!, trigger: .manual, occurrence: nil)
        run.state = .needsApproval; run.finished = Date().addingTimeInterval(-8 * 86400)
        try center.store.saveRun(run)
        let raw = try JSONSerialization.data(withJSONObject: ["version": 1, "summary": "s", "items": [
            ["id": "t", "op": "tag", "path": work + "/a.txt", "tags": ["Red"], "reason": "r"]
        ]])
        try center.store.writeRunFile(automationID: a.id, runID: run.id, name: RunEngine.proposalRawFile, data: raw)
        XCTAssertNil(center.approve(run, items: ["t"]))
        XCTAssertEqual(center.store.run(automationID: a.id, runID: run.id)?.state, .expired)
    }

    func testRunnerStatusMapping() {
        let now = Date()
        let fresh = RunnerHeartbeat(pid: 1, started: now.addingTimeInterval(-600), heartbeat: now.addingTimeInterval(-10), version: "1", signedBuild: true)
        let old = RunnerHeartbeat(pid: 1, started: now.addingTimeInterval(-600), heartbeat: now.addingTimeInterval(-200), version: "1", signedBuild: true)
        typealias C = AutomationCenter
        XCTAssertEqual(C.runnerStatus(signed: false, service: .enabled, heartbeat: fresh, enabledSince: nil, now: now), .unsignedBuild)
        XCTAssertEqual(C.runnerStatus(signed: true, service: .notRegistered, heartbeat: nil, enabledSince: nil, now: now), .off)
        XCTAssertEqual(C.runnerStatus(signed: true, service: .requiresApproval, heartbeat: nil, enabledSince: nil, now: now), .needsApproval)
        XCTAssertEqual(C.runnerStatus(signed: true, service: .notFound, heartbeat: nil, enabledSince: nil, now: now), .failed("Runner missing from app bundle"))
        XCTAssertEqual(C.runnerStatus(signed: true, service: .enabled, heartbeat: fresh, enabledSince: nil, now: now), .running(since: fresh.started))
        XCTAssertEqual(C.runnerStatus(signed: true, service: .enabled, heartbeat: old, enabledSince: now.addingTimeInterval(-30), now: now), .starting)
        XCTAssertEqual(C.runnerStatus(signed: true, service: .enabled, heartbeat: old, enabledSince: now.addingTimeInterval(-120), now: now), .notResponding)
    }

    func testImportAnchorIsNextBoundary() {
        let zone = TimeZone(identifier: "Europe/London")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9, minute: 17))!
        let anchor = AutomationCenter.importAnchor("RRULE:FREQ=HOURLY;INTERVAL=4", zone: zone, now: now)
        XCTAssertEqual(anchor, cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12, minute: 0)))
        XCTAssertEqual(AutomationCenter.importAnchor("nonsense", zone: zone, now: now), now)
    }

    func testClientSeedsOnlyExistingFiles() throws {
        let home = base.path
        XCTAssertTrue(AutomationCenter.seedClients(home: home).isEmpty)
        let folder = home + "/Dev/docs/4-delivery/clients/robert-parish/meta-ads"
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: folder + "/robert-parish-dashboard.metrics.json"))
        try Data("<html></html>".utf8).write(to: URL(fileURLWithPath: folder + "/robert-parish-dashboard.html"))
        let seeded = AutomationCenter.seedClients(home: home)
        XCTAssertEqual(seeded.map(\.id), ["robert-parish"])
        XCTAssertEqual(seeded.first?.profile, .robertParish)
        XCTAssertEqual(seeded.first?.dashboardPath, folder + "/robert-parish-dashboard.html")
    }

    func testAlertActionsRoute() {
        var opened: [(String?, String?)] = []
        center.openWindow = { opened.append(($0, $1)) }
        XCTAssertTrue(center.handleAlertAction("run:tidy-1/20260926T080000Z-abcd", "review"))
        XCTAssertTrue(center.handleAlertAction("run:tidy-1/20260926T080000Z-abcd", "later"))
        XCTAssertFalse(center.handleAlertAction("quill:x", "open"))
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, "tidy-1")
        XCTAssertEqual(opened.first?.1, "20260926T080000Z-abcd")
    }
}
