import Foundation

/// A fixed process launch built by code: no shell, explicit environment, prompt on stdin.
public struct ProcessLaunch: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var stdin: Data
    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, stdin: Data) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.stdin = stdin
    }
}

public enum RunnerCommandError: Error, Equatable, CustomStringConvertible {
    case cliMissing(AgentRunner)
    case invalidSession
    case resumeUnsupported(String)
    public var description: String {
        switch self {
        case .cliMissing(let r): return "The \(r.executableName) CLI was not found. Set its path in Settings › Automations."
        case .invalidSession: return "The saved session ID is not valid, so the run cannot continue."
        case .resumeUnsupported(let why): return why
        }
    }
}

/// Builds agent command lines. Access is enforced by the CLI (Codex sandbox, Claude tool list), never by prompt text.
public enum RunnerCommand {
    /// Environment names copied from the runner's own environment. Everything else is dropped,
    /// including API keys and base-URL overrides, so the CLIs use the signed-in subscription.
    public static let passedEnvironment = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]
    /// Never passed, even if a script lists them.
    public static let blockedEnvironment: Set<String> = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                                                         "CODEX_API_KEY", "OPENROUTER_API_KEY"]

    public static func isBlocked(_ name: String) -> Bool {
        blockedEnvironment.contains(name) || name.hasSuffix("_BASE_URL")
    }

    /// A minimal environment: a few names from `base` plus `PATH`.
    public static func environment(base: [String: String], path: String) -> [String: String] {
        var env: [String: String] = [:]
        for key in passedEnvironment { if let v = base[key] { env[key] = v } }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["PATH"] = path
        return env
    }

    public static func claudeTools(_ access: AgentAccess) -> [String] {
        switch access {
        case .readOnly: return ["Read", "Glob", "Grep"]
        case .workspaceWrite: return ["Read", "Glob", "Grep", "Edit", "Write"]
        case .workspaceWriteNetwork: return ["Read", "Glob", "Grep", "Edit", "Write", "WebFetch", "WebSearch"]
        }
    }

    public struct Files: Equatable, Sendable {
        /// The JSON schema file (Codex reads it from disk).
        public var schemaFile: URL
        /// Codex writes its final message here.
        public var lastMessageFile: URL
        /// Claude only: sign-in values from `ClaudeSignIn`, passed with `--settings`.
        public var claudeSettingsFile: URL?
        public init(schemaFile: URL, lastMessageFile: URL, claudeSettingsFile: URL? = nil) {
            self.schemaFile = schemaFile; self.lastMessageFile = lastMessageFile; self.claudeSettingsFile = claudeSettingsFile
        }
    }

    /// The full launch for one agent turn. `cliPath` is the resolved CLI from settings.
    /// `resumeSession` continues a session this run created (ask mode).
    public static func agent(_ task: AgentTask, cliPath: String, prompt: String, schema: String, files: Files,
                             resumeSession: String? = nil, baseEnvironment: [String: String], path: String) throws -> ProcessLaunch {
        guard cliPath.hasPrefix("/") else { throw RunnerCommandError.cliMissing(task.runner) }
        if let resumeSession, UUID(uuidString: resumeSession) == nil { throw RunnerCommandError.invalidSession }
        // The CLI's own folder first: a Node-based CLI needs `node` beside it.
        let cliDir = URL(fileURLWithPath: cliPath).deletingLastPathComponent().path
        let env = environment(base: baseEnvironment, path: ([cliDir] + path.split(separator: ":").map(String.init).filter { $0 != cliDir }).joined(separator: ":"))
        let args: [String]
        switch task.runner {
        case .codex: args = codexArguments(task, schemaFile: files.schemaFile, lastMessage: files.lastMessageFile, resume: resumeSession)
        case .claude: args = claudeArguments(task, schema: schema, resume: resumeSession, settingsFile: files.claudeSettingsFile)
        }
        return ProcessLaunch(executable: cliPath, arguments: args, environment: env,
                             workingDirectory: task.workingDirectory, stdin: Data(prompt.utf8))
    }

    static func effortValue(_ effort: ReasoningEffort) -> String? { effort == .none ? nil : effort.rawValue }

    static func codexArguments(_ task: AgentTask, schemaFile: URL, lastMessage: URL, resume: String?) -> [String] {
        let sandbox = task.access == .readOnly ? "read-only" : "workspace-write"
        var a = ["exec"]
        if resume != nil { a.append("resume") }
        a += ["--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json"]
        if resume == nil {
            a += ["-s", sandbox]
        } else {
            // `exec resume` has no -s, -C or --add-dir; the same limits go in as config overrides,
            // and the process working folder is the task's folder.
            a += ["-c", "sandbox_mode=\"\(sandbox)\""]
            if task.access.canWrite { a += ["-c", "sandbox_workspace_write.writable_roots=\(tomlArray(task.allowedRoots))"] }
        }
        if !task.model.isEmpty { a += ["-m", task.model] }
        if let e = effortValue(task.effort) { a += ["-c", "model_reasoning_effort=\"\(e)\""] }
        if task.fast { a += ["-c", "service_tier=\"fast\""] }
        if task.access.usesNetwork { a += ["-c", "sandbox_workspace_write.network_access=true"] }
        if resume == nil {
            a += ["-C", task.workingDirectory]
            if task.access.canWrite { for root in task.allowedRoots { a += ["--add-dir", root] } }
        }
        a += ["--output-schema", schemaFile.path, "-o", lastMessage.path]
        if let resume { a.append(resume) }
        a.append("-")
        return a
    }

    static func claudeArguments(_ task: AgentTask, schema: String, resume: String?, settingsFile: URL? = nil) -> [String] {
        let tools = claudeTools(task.access).joined(separator: ",")
        var a = ["-p", "--output-format", "stream-json", "--verbose", "--restricted", "--safe-mode", "--strict-mcp-config",
                 "--permission-prompts", "none", "--tools", tools, "--allowedTools", tools, "--json-schema", schema]
        if !task.model.isEmpty { a += ["--model", task.model] }
        if let e = effortValue(task.effort) { a += ["--effort", e] }
        for root in task.allowedRoots { a += ["--add-dir", root] }
        if let settingsFile { a += ["--settings", settingsFile.path] }
        if let resume { a += ["--resume", resume] }
        return a
    }

    /// TOML array of basic strings. JSON string escapes are valid TOML basic-string escapes.
    static func tomlArray(_ values: [String]) -> String {
        let items = values.map { v -> String in
            let data = (try? JSONSerialization.data(withJSONObject: [v], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// Flags that would lift the CLI's limits. Never produced; tests assert this.
    public static let forbiddenArguments = ["--dangerously-bypass-approvals-and-sandbox", "danger-full-access",
                                            "--dangerously-skip-permissions", "bypassPermissions", "Bash"]
}
