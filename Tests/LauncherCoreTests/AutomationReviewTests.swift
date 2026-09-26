import XCTest
@testable import LauncherCore

final class AutomationReviewTests: XCTestCase {
    private var directory: URL!
    private var store: AutomationStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AutomationStore(root: directory.appendingPathComponent("Automations"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func automation() -> Automation {
        Automation(id: "review-1", name: "Review", kind: .script(ScriptTask(executable: "/usr/bin/touch",
                   arguments: [directory.appendingPathComponent("ran").path], workingDirectory: directory.path)),
                   schedule: Schedule(rule: .manual))
    }

    func testQueueOverflowDoesNotClassifyValidRequestsAsUnreadable() throws {
        try store.ensureRoot()
        let requests = store.root.appendingPathComponent("requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: false)
        for _ in 0..<1002 {
            let request = RunnerRequest(action: .reload)
            try AutomationJSON.encoder().encode(request).write(to: requests.appendingPathComponent(request.id + ".json"))
        }
        XCTAssertEqual(store.pendingRequests().count, 1000)
        XCTAssertEqual(store.unreadableRequestIDs(), [])
    }

    func testDirectDefinitionReadRejectsMismatchedIDAndSymlinkFolder() throws {
        var definition = automation()
        try store.save(definition)
        definition.id = "different"
        let folder = store.root.appendingPathComponent("review-1")
        try AutomationJSON.encoder().encode(definition).write(to: folder.appendingPathComponent("automation.json"))
        XCTAssertNil(store.automation(id: "review-1"))
        try FileManager.default.moveItem(at: folder, to: directory.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: directory.appendingPathComponent("outside"))
        XCTAssertNil(store.automation(id: "review-1"))
    }

    func testRunDoesNotStartWhenStateCannotBeSaved() throws {
        let definition = automation()
        try Data().write(to: store.root)
        let run = RunRecord(id: RunID.make(), automation: definition, trigger: .manual, occurrence: nil)
        let result = RunEngine(store: store, context: .init(settings: AutomationSettings())).execute(run, automation: definition)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.error?.contains("could not be saved") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path))
    }

    func testQueuedDefinitionChangeDoesNotRunNewCommand() throws {
        var definition = automation()
        let run = RunRecord(id: RunID.make(), automation: definition, trigger: .manual, occurrence: nil)
        definition.revision += 1
        let result = RunEngine(store: store, context: .init(settings: AutomationSettings())).execute(run, automation: definition)
        XCTAssertEqual(result.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path))
    }

    func testPreCancelledProcessDoesNotStart() {
        let supervisor = ProcessSupervisor()
        supervisor.cancel()
        let launch = ProcessLaunch(executable: "/usr/bin/touch", arguments: [directory.appendingPathComponent("ran").path],
                                   environment: [:], workingDirectory: directory.path, stdin: Data())
        XCTAssertEqual(supervisor.run(launch, timeout: 2).reason, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path))
    }

    func testFIFOReadsFailWithoutWaitingForWriter() throws {
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try SecureFile.read(fifo, maxBytes: 1024))
        XCTAssertThrowsError(try ClientMetricsReader.read(url: fifo, profile: .stein))
    }

    func testScriptOutputRedactsExplicitEnvironmentValues() throws {
        let script = ScriptTask(executable: "/usr/bin/printenv", arguments: ["PRIVATE_TOKEN"],
                                workingDirectory: directory.path, environment: ["PRIVATE_TOKEN": "secret-value-123"])
        let definition = Automation(id: "redact-1", name: "Redact", kind: .script(script), schedule: Schedule(rule: .manual))
        let run = RunRecord(id: RunID.make(), automation: definition, trigger: .manual, occurrence: nil)
        let result = RunEngine(store: store, context: .init(settings: AutomationSettings())).execute(run, automation: definition)
        XCTAssertEqual(result.state, .succeeded)
        XCTAssertFalse(try XCTUnwrap(store.readOutput(result)).contains("secret-value-123"))
    }
    func testStateAccessRejectsIntermediateSymlinks() throws {
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let file = outside.appendingPathComponent("state.json")
        try Data("private".utf8).write(to: file)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let linked = alias.appendingPathComponent("state.json")
        XCTAssertThrowsError(try SecureFile.read(linked, maxBytes: 100))
        XCTAssertThrowsError(try SecureFile.write(Data("changed".utf8), to: linked))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "private")
    }

    func testRunnerLockRejectsLinksAndExcludesSecondOwner() throws {
        let first = try XCTUnwrap(store.acquireRunnerLock())
        defer { close(first) }
        XCTAssertNil(try store.acquireRunnerLock())
        let other = AutomationStore(root: directory.appendingPathComponent("linked-store"))
        try other.ensureRoot()
        let target = directory.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: other.root.appendingPathComponent("runner.lock"), withDestinationURL: target)
        XCTAssertThrowsError(try other.acquireRunnerLock())
    }

}
