import XCTest
@testable import LauncherCore

final class CodexImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ id: String, _ body: String) throws {
        let dir = folder.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appendingPathComponent("automation.toml"), atomically: true, encoding: .utf8)
    }

    private func toml(id: String, status: String = "PAUSED", prompt: String) -> String {
        """
        version = 1
        id = "\(id)"
        kind = "heartbeat"
        name = "Sample job"
        prompt = "\(prompt)"
        status = "\(status)"
        rrule = "RRULE:FREQ=HOURLY;INTERVAL=4"
        target_thread_id = "thread-1"
        created_at = 1783628472879
        updated_at = 1783628472999
        """
    }

    func testReadsEntriesAndKeepsErrorsVisible() throws {
        try write("good", toml(id: "good", prompt: "Use gpt-test with extra high reasoning for this task.\\nIn /tmp, read things."))
        try write("mismatch", toml(id: "other", prompt: "x"))
        try write("broken", "version = 1\nversion = 2\n")
        try write("future", toml(id: "future", prompt: "x").replacingOccurrences(of: "version = 1", with: "version = 2"))
        let entries = CodexImport.readAll(folder: folder)
        XCTAssertEqual(entries.map(\.id), ["broken", "future", "good", "mismatch"])
        let good = entries[2]
        XCTAssertNil(good.error)
        XCTAssertEqual(good.status, .paused)
        XCTAssertEqual(good.createdAt, 1783628472879)
        XCTAssertEqual(good.hash.count, 64)
        XCTAssertTrue(good.prompt.contains("\n"))
        XCTAssertNotNil(entries[0].error)
        XCTAssertEqual(entries[1].error, "Unsupported version 2")
        XCTAssertEqual(entries[3].error, "ID does not match its folder")
    }

    func testRefusesSymlinks() throws {
        try write("real", toml(id: "real", prompt: "x"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: folder.appendingPathComponent("real"))
        let dir = folder.appendingPathComponent("filelink")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("automation.toml"),
                                                   withDestinationURL: folder.appendingPathComponent("real/automation.toml"))
        let entries = Dictionary(uniqueKeysWithValues: CodexImport.readAll(folder: folder).map { ($0.id, $0) })
        XCTAssertEqual(entries["link"]?.error, "Folder is a symbolic link")
        XCTAssertEqual(entries["filelink"]?.error, "File is a symbolic link")
        XCTAssertNil(entries["real"]?.error)
    }

    func testSuggestion() {
        let exists: (String) -> Bool = { $0 == "/Users/test/Dev/docs" }
        let s = CodexImport.suggestion(for: "Use gpt-6-astra with low reasoning for this.\nWork from /Users/test/Dev/docs. Then go.", folderExists: exists)
        XCTAssertEqual(s.model, "gpt-6-astra")
        XCTAssertEqual(s.effort, .low)
        XCTAssertEqual(s.workingDirectory, "/Users/test/Dev/docs")
        XCTAssertEqual(CodexImport.suggestion(for: "Use m with Extra High reasoning", folderExists: exists).effort, .xhigh)
        XCTAssertEqual(CodexImport.suggestion(for: "Use m with xhigh reasoning", folderExists: exists).effort, .xhigh)
        let none = CodexImport.suggestion(for: "Do things.\nUse m with low reasoning. In /nope, go.", folderExists: exists)
        XCTAssertNil(none.model)
        XCTAssertNil(none.workingDirectory)
    }

    func testMakeAutomationIsPausedAndKeepsPrompt() {
        let prompt = "Use gpt-6-astra with high reasoning.\nIn /Users/test/w, summarize the log. Use subagents. Commit nothing."
        let codex = CodexAutomation(id: "sample", name: "Sample job", kind: "heartbeat", status: .active,
                                    rrule: "RRULE:FREQ=DAILY;BYHOUR=4", prompt: prompt, path: "/x/sample/automation.toml", hash: "abc")
        let exists: (String) -> Bool = { $0 == "/Users/test/w" }
        let a = CodexImport.makeAutomation(from: codex, timeZone: "Europe/London", anchor: Date(timeIntervalSince1970: 0), folderExists: exists)
        XCTAssertFalse(a.enabled)
        XCTAssertEqual(a.schedule.rule, .rrule("FREQ=DAILY;BYHOUR=4"))
        XCTAssertEqual(a.source, .init(app: .codex, sourceID: "sample", path: "/x/sample/automation.toml", hash: "abc"))
        guard case .agent(let task) = a.kind else { return XCTFail("not agent") }
        XCTAssertEqual(task.prompt, prompt)
        XCTAssertEqual(task.model, "gpt-6-astra")
        XCTAssertEqual(task.effort, .high)
        XCTAssertEqual(task.workingDirectory, "/Users/test/w")
        XCTAssertEqual(task.access, .readOnly)
        XCTAssertEqual(task.output, .report)
        XCTAssertEqual(task.runner, .codex)
        let issues = CodexImport.importIssues(for: codex, folderExists: exists)
        XCTAssertTrue(issues.contains { $0.contains("Still active") })
        XCTAssertTrue(issues.contains { $0.contains("committing") })
        XCTAssertTrue(issues.contains { $0.contains("subagents") })
        XCTAssertFalse(issues.contains { $0.contains("working folder") })
        let bare = CodexAutomation(id: "b", status: .paused, prompt: "Summarize.", path: "/x")
        XCTAssertEqual(CodexImport.importIssues(for: bare, folderExists: exists).count, 3)
    }

    func testIsActiveInCodexFailsClosed() throws {
        try write("on", toml(id: "on", status: "ACTIVE", prompt: "x"))
        try write("off", toml(id: "off", prompt: "x"))
        XCTAssertTrue(CodexImport.isActiveInCodex(path: folder.appendingPathComponent("on/automation.toml").path))
        XCTAssertFalse(CodexImport.isActiveInCodex(path: folder.appendingPathComponent("off/automation.toml").path))
        XCTAssertTrue(CodexImport.isActiveInCodex(path: folder.appendingPathComponent("missing/automation.toml").path))
    }

    /// Parses the real Codex folder when present. Prints no prompt text.
    func testRealCodexFilesParse() throws {
        let real = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/automations")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: real.path), "No Codex automations folder")
        let entries = CodexImport.readAll(folder: real)
        XCTAssertFalse(entries.isEmpty)
        for e in entries {
            XCTAssertNil(e.error, "\(e.id): \(e.error ?? "")")
            XCTAssertNotNil(CodexImport.suggestion(for: e.prompt).model, "\(e.id) has no model line")
        }
    }
}
