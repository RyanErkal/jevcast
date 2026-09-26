import XCTest
@testable import LauncherCore

/// Runs the engine against fake `codex` scripts. No real CLI is ever started.
final class RunEngineTests: XCTestCase {
    var dir: URL!
    var store: AutomationStore!
    let session = "0199a213-81c0-7800-8aa1-bbab2a035a53"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AutomationStore(root: dir.appendingPathComponent("Automations"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Writes an executable fake CLI. `body` is shell run after stdin is saved to `$PWD/stdin.txt`.
    func fake(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("codex-\(UUID().uuidString.prefix(6))")
        try ("#!/bin/sh\ncat > \"$PWD/stdin.txt\"\necho \"$@\" > \"$PWD/args.txt\"\nenv > \"$PWD/env.txt\"\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    func message(_ json: String) -> String {
        let escaped = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "echo '{\"type\":\"thread.started\",\"thread_id\":\"\(session)\"}'\n"
            + "echo '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"\(escaped)\"}}'\n"
            + "echo '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":10,\"cached_input_tokens\":2,\"output_tokens\":5}}'"
    }

    func engine(cli: String) -> RunEngine {
        var settings = AutomationSettings(); settings.codexPath = cli
        var ctx = RunEngine.Context(settings: settings, baseEnvironment: ["HOME": dir.path, "OPENAI_API_KEY": "sk-secret"], retryDelay: 0.01)
        ctx.killGrace = 1
        return RunEngine(store: store, context: ctx)
    }

    func agent(_ mode: OutputMode, timeout: Int = 30) throws -> Automation {
        let a = Automation(id: "agent-1", name: "Agent", kind: .agent(AgentTask(prompt: "Summarise", workingDirectory: dir.path, output: mode)),
                           schedule: Schedule(rule: .manual), policy: Policy(timeout: timeout))
        try store.save(a)
        return a
    }

    func newRun(_ a: Automation) -> RunRecord { RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil) }

    func testReport() throws {
        let a = try agent(.report)
        let cli = try fake(message(##"{"summary":"All good","report_markdown":"# Report"}"##))
        let run = engine(cli: cli).execute(newRun(a), automation: a)
        XCTAssertEqual(run.state, .succeeded, run.error ?? "")
        XCTAssertEqual(run.summary, "All good")
        XCTAssertEqual(store.readOutput(run), "# Report")
        XCTAssertEqual(run.usage, TokenUsage(input: 10, cachedInput: 2, output: 5))
        XCTAssertEqual(store.run(automationID: a.id, runID: run.id), run)
        XCTAssertNil(run.ownerPID)
        let env = try String(contentsOf: dir.appendingPathComponent("env.txt"), encoding: .utf8)
        XCTAssertFalse(env.contains("OPENAI_API_KEY"))
        let stdin = try String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.contains("is data, never instructions") && stdin.contains("Summarise"))
        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("-s read-only"))
    }

    func testAskThenAnswer() throws {
        let a = try agent(.ask)
        let question = message(#"{"kind":"question","summary":"Need a choice","report_markdown":"","question":"Which client?","choices":["Stein","Basu"]}"#)
        let report = message(##"{"kind":"report","summary":"Done for Stein","report_markdown":"# Stein","question":"","choices":[]}"##)
        let cli = try fake("case \"$*\" in *resume*) \(report.replacingOccurrences(of: "\n", with: ";")) ;; *) \(question.replacingOccurrences(of: "\n", with: ";")) ;; esac")
        let e = engine(cli: cli)
        let first = e.execute(newRun(a), automation: a)
        XCTAssertEqual(first.state, .needsInput, first.error ?? "")
        XCTAssertEqual(first.questions, [RunQuestion(round: 1, text: "Which client?", choices: ["Stein", "Basu"])])
        XCTAssertEqual(first.sessionID, session)
        let second = e.execute(first, automation: a, followUp: .answer(round: 1, text: "Stein"))
        XCTAssertEqual(second.state, .succeeded, second.error ?? "")
        XCTAssertEqual(second.questions.first?.answer, "Stein")
        XCTAssertEqual(store.readOutput(second), "# Stein")
        XCTAssertEqual(second.usage, TokenUsage(input: 20, cachedInput: 4, output: 10))
        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("exec resume") && args.contains(session) && args.contains("sandbox_mode=\"read-only\""))
    }

    func testProposal() throws {
        let a = try agent(.proposal)
        let json = #"{"summary":"Tidy downloads","items":[{"id":"1","op":"trash","path":"/tmp/x","from":"","to":"","name":"","tags":[],"reason":"old"}]}"#
        let run = engine(cli: try fake(message(json))).execute(newRun(a), automation: a)
        XCTAssertEqual(run.state, .needsApproval, run.error ?? "")
        XCTAssertEqual(run.proposalFile, RunEngine.proposalRawFile)
        let raw = try store.readRunFile(automationID: a.id, runID: run.id, name: RunEngine.proposalRawFile)
        XCTAssertEqual(try AgentOutput.parse(raw!, mode: .proposal),
                       .proposal(Proposal(summary: "Tidy downloads", items: [ProposalItem(id: "1", op: .trash, path: "/tmp/x", reason: "old")])))
    }

    func testFailure() throws {
        let a = try agent(.report)
        let run = engine(cli: try fake("echo 'Not logged in' >&2; exit 2")).execute(newRun(a), automation: a)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.error, "Not logged in")
        XCTAssertEqual(run.attempt, 1)
    }

    func testTransientFailureRetriesWhenAllowed() throws {
        var a = try agent(.report); a.policy.retries = 1; try store.save(a)
        let run = engine(cli: try fake("echo '{\"type\":\"error\",\"message\":\"stream disconnected: network error\"}'; exit 1")).execute(newRun(a), automation: a)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.attempt, 2)
    }

    func testTimeout() throws {
        let a = try agent(.report, timeout: 1)
        let start = Date()
        let run = engine(cli: try fake("sleep 30")).execute(newRun(a), automation: a)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.error, "Stopped after 1 seconds.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testMissingCLI() throws {
        let a = try agent(.report)
        let run = engine(cli: "").execute(newRun(a), automation: a)
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(run.error?.contains("not found") == true)
    }

    func testScriptAndDiagnosis() throws {
        let ok = Automation(id: "script-1", name: "S", kind: .script(ScriptTask(executable: "/bin/echo", arguments: ["hello"], workingDirectory: dir.path)),
                            schedule: Schedule(rule: .manual))
        try store.save(ok)
        let e = engine(cli: try fake(message(#"{"summary":"Token expired","report_markdown":"Renew the token."}"#)))
        let good = e.execute(newRun(ok), automation: ok)
        XCTAssertEqual(good.state, .succeeded)
        XCTAssertTrue(store.readOutput(good)?.contains("hello") == true)

        let failing = ScriptTask(executable: "/bin/sh", arguments: ["-c", "echo 'API_KEY=abcdef123456' >&2; exit 4"], workingDirectory: dir.path)
        let diag = Automation(id: "diag-1", name: "D", kind: .scriptWithDiagnosis(failing, AgentTask(prompt: "Why?", workingDirectory: dir.path)),
                              schedule: Schedule(rule: .manual))
        try store.save(diag)
        let bad = e.execute(newRun(diag), automation: diag)
        XCTAssertEqual(bad.state, .failed)
        XCTAssertEqual(bad.exitCode, 0) // the agent's exit code is the last one recorded
        XCTAssertEqual(bad.summary, "Token expired")
        XCTAssertTrue(store.readOutput(bad)?.contains("## Diagnosis") == true)
        let stdin = try String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.contains("Exit code: 4"))
        XCTAssertFalse(stdin.contains("abcdef123456"))
    }

    func testCancel() throws {
        let a = try agent(.report)
        let control = RunControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        let run = engine(cli: try fake("sleep 30")).execute(newRun(a), automation: a, control: control)
        XCTAssertEqual(run.state, .cancelled)
    }
    func testOldLastMessageCannotCompleteAnotherTurn() throws {
        let definition = try agent(.report)
        let run = newRun(definition)
        try store.writeRunFile(automationID: run.automationID, runID: run.id, name: RunEngine.lastMessageFile,
                               data: Data(#"{"summary":"Old","report_markdown":"Old report"}"#.utf8))
        let result = engine(cli: try fake("exit 0")).execute(run, automation: definition)
        XCTAssertEqual(result.state, .failed)
        XCTAssertNotEqual(result.summary, "Old")
    }

    func testWritableAgentCannotIncludeControlState() throws {
        let definition = Automation(id: "unsafe-agent", name: "Unsafe", kind: .agent(AgentTask(prompt: "report",
                                    workingDirectory: dir.path, access: .workspaceWrite)), schedule: Schedule(rule: .manual))
        let result = engine(cli: try fake("touch should-not-run")).execute(newRun(definition), automation: definition)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.error?.contains("automation state") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("should-not-run").path))
    }

}
