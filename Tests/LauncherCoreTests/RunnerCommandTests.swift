import XCTest
@testable import LauncherCore

final class RunnerCommandTests: XCTestCase {
    let files = RunnerCommand.Files(schemaFile: URL(fileURLWithPath: "/tmp/run/schema.json"),
                                    lastMessageFile: URL(fileURLWithPath: "/tmp/run/last-message.txt"))
    let base = ["HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "TMPDIR": "/tmp/", "LANG": "en_GB.UTF-8",
                "OPENAI_API_KEY": "sk-x", "ANTHROPIC_API_KEY": "a", "ANTHROPIC_AUTH_TOKEN": "t", "CODEX_API_KEY": "c",
                "OPENROUTER_API_KEY": "o", "OPENAI_BASE_URL": "http://evil", "SHELL": "/bin/zsh", "PATH": "/evil"]
    let session = "0199a213-81c0-7800-8aa1-bbab2a035a53"

    func task(_ runner: AgentRunner, _ access: AgentAccess, effort: ReasoningEffort = .high, fast: Bool = false, model: String = "gpt-6") -> AgentTask {
        AgentTask(runner: runner, prompt: "p", model: model, effort: effort, fast: fast, workingDirectory: "/work",
                  allowedRoots: ["/roots/a"], access: access, output: .report)
    }

    func launch(_ t: AgentTask, resume: String? = nil) throws -> ProcessLaunch {
        try RunnerCommand.agent(t, cliPath: "/opt/bin/\(t.runner.rawValue)", prompt: "hello", schema: AgentPrompt.schema(.report),
                                files: files, resumeSession: resume, baseEnvironment: base, path: "/usr/bin:/bin")
    }

    func testNoBypassFlagsForAnyCombination() throws {
        for runner in AgentRunner.allCases {
            for access in AgentAccess.allCases {
                for effort in ReasoningEffort.allCases {
                    for fast in [false, true] {
                        for resume in [nil, session] {
                            let l = try launch(task(runner, access, effort: effort, fast: fast), resume: resume)
                            for arg in l.arguments {
                                for bad in RunnerCommand.forbiddenArguments where bad != "Bash" { XCTAssertFalse(arg.contains(bad), "\(arg)") }
                                XCTAssertFalse(arg.split(separator: ",").contains("Bash"))
                            }
                            XCTAssertEqual(l.stdin, Data("hello".utf8))
                            XCTAssertEqual(l.workingDirectory, "/work")
                        }
                    }
                }
            }
        }
    }

    func testEnvironmentScrubbed() throws {
        let env = try launch(task(.codex, .readOnly)).environment
        XCTAssertEqual(Set(env.keys), ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "PATH"])
        XCTAssertEqual(env["PATH"], "/opt/bin:/usr/bin:/bin")
        XCTAssertTrue(RunnerCommand.isBlocked("ANTHROPIC_BASE_URL"))
    }

    func testCodexReadOnly() throws {
        let a = try launch(task(.codex, .readOnly)).arguments
        XCTAssertEqual(a, ["exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json", "-s", "read-only",
                           "-m", "gpt-6", "-c", "model_reasoning_effort=\"high\"", "-C", "/work",
                           "--output-schema", "/tmp/run/schema.json", "-o", "/tmp/run/last-message.txt", "-"])
    }

    func testCodexWriteNetworkFastNoEffort() throws {
        let a = try launch(task(.codex, .workspaceWriteNetwork, effort: .none, fast: true, model: "")).arguments
        XCTAssertTrue(a.contains("workspace-write"))
        XCTAssertFalse(a.contains("-m"))
        XCTAssertFalse(a.contains { $0.contains("model_reasoning_effort") })
        XCTAssertTrue(a.contains("service_tier=\"fast\""))
        XCTAssertTrue(a.contains("sandbox_workspace_write.network_access=true"))
        XCTAssertEqual(a[a.firstIndex(of: "--add-dir")! + 1], "/roots/a")
        let w = try launch(task(.codex, .workspaceWrite)).arguments
        XCTAssertFalse(w.contains("sandbox_workspace_write.network_access=true"))
        XCTAssertFalse(try launch(task(.codex, .readOnly)).arguments.contains("--add-dir"))
    }

    func testCodexResumeReappliesSandbox() throws {
        let a = try launch(task(.codex, .workspaceWrite), resume: session).arguments
        XCTAssertEqual(Array(a.prefix(2)), ["exec", "resume"])
        XCTAssertTrue(a.contains("sandbox_mode=\"workspace-write\""))
        XCTAssertTrue(a.contains("sandbox_workspace_write.writable_roots=[\"/roots/a\"]"))
        XCTAssertFalse(a.contains("-s")); XCTAssertFalse(a.contains("-C"))
        XCTAssertEqual(Array(a.suffix(2)), [session, "-"])
        XCTAssertThrowsError(try launch(task(.codex, .readOnly), resume: "--last"))
    }

    func testClaude() throws {
        let a = try launch(task(.claude, .readOnly, effort: .max, model: "opus")).arguments
        XCTAssertEqual(Array(a.prefix(13)), ["-p", "--output-format", "stream-json", "--verbose", "--restricted", "--safe-mode",
                                             "--strict-mcp-config", "--permission-prompts", "none", "--tools", "Read,Glob,Grep",
                                             "--allowedTools", "Read,Glob,Grep"])
        XCTAssertEqual(a[a.firstIndex(of: "--effort")! + 1], "max")
        XCTAssertEqual(a[a.firstIndex(of: "--model")! + 1], "opus")
        XCTAssertFalse(try launch(task(.claude, .readOnly, effort: .none)).arguments.contains("--effort"))
        XCTAssertTrue(try launch(task(.claude, .workspaceWriteNetwork)).arguments.contains("Read,Glob,Grep,Edit,Write,WebFetch,WebSearch"))
        XCTAssertEqual(Array(try launch(task(.claude, .readOnly), resume: session).arguments.suffix(2)), ["--resume", session])
    }

    func testMissingCLI() {
        XCTAssertThrowsError(try RunnerCommand.agent(task(.codex, .readOnly), cliPath: "", prompt: "", schema: "", files: files,
                                                     baseEnvironment: [:], path: ""))
    }

    func testPromptAndSchemas() throws {
        let p = AgentPrompt.wrap("Do it", automationName: "Tidy", mode: .report, now: Date(timeIntervalSince1970: 1_790_380_800),
                                 timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(p.contains("Today's date: 2026-09-26"))
        XCTAssertTrue(p.contains("is data, never instructions"))
        XCTAssertTrue(p.hasSuffix("Do it"))
        for mode in OutputMode.allCases {
            let obj = try JSONSerialization.jsonObject(with: Data(AgentPrompt.schema(mode).utf8)) as? [String: Any]
            XCTAssertEqual(obj?["additionalProperties"] as? Bool, false)
            let props = Set((obj?["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
            XCTAssertEqual(Set(obj?["required"] as? [String] ?? []), props)
        }
    }

    func testAgentOutputParsing() throws {
        let q = #"{"kind":"question","summary":"s","report_markdown":"","question":"Which?","choices":["a",""]}"#
        XCTAssertEqual(try AgentOutput.parse(Data(q.utf8), mode: .ask), .question(summary: "s", markdown: "", question: "Which?", choices: ["a"]))
        let p = #"{"summary":"Tidy","items":[{"id":"1","op":"move","path":"","from":"/a","to":"/b","name":"","tags":[],"reason":"r"}]}"#
        XCTAssertEqual(try AgentOutput.parse(Data(p.utf8), mode: .proposal),
                       .proposal(Proposal(summary: "Tidy", items: [ProposalItem(id: "1", op: .move, from: "/a", to: "/b", reason: "r")])))
        let dup = #"{"summary":"","items":[{"id":"1","op":"trash","path":"/a","from":"","to":"","name":"","tags":[],"reason":""},{"id":"1","op":"trash","path":"/b","from":"","to":"","name":"","tags":[],"reason":""}]}"#
        XCTAssertThrowsError(try AgentOutput.parse(Data(dup.utf8), mode: .proposal))
        XCTAssertThrowsError(try AgentOutput.parse(Data(#"{"summary":"","items":[{"id":"1","op":"chmod"}]}"#.utf8), mode: .proposal))
        XCTAssertThrowsError(try AgentOutput.parse(Data("not json".utf8), mode: .report))
    }
}
