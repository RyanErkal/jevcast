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

    /// Extra limits for one launch. The defaults keep the saved task's own behaviour.
    public struct Options: Equatable, Sendable {
        /// Run without saving a session (Codex `--ephemeral`). Only for turns no one resumes.
        public var ephemeral: Bool
        /// Codex: do not add `/tmp` and `$TMPDIR` to the writable folders, so only the task's folders are writable.
        public var excludeTemporaryFolders: Bool
        /// Codex: turn off tools that reach outside the sandbox (apps, browser, computer use, plugins, web search).
        public var noRemoteTools: Bool
        /// Codex: the worker's only tool. The shell is off; this one fixed server is its whole reach.
        public var toolServer: ToolServer?
        public init(ephemeral: Bool = false, excludeTemporaryFolders: Bool = false, noRemoteTools: Bool = false,
                    toolServer: ToolServer? = nil) {
            self.ephemeral = ephemeral; self.excludeTemporaryFolders = excludeTemporaryFolders
            self.noRemoteTools = noRemoteTools || toolServer != nil; self.toolServer = toolServer
        }
    }

    /// One stdio MCP server Jevcast starts for a worker. Its program is Jevcast's own signed runner.
    public struct ToolServer: Equatable, Sendable {
        public var name: String
        public var command: String
        public var arguments: [String]
        /// The one tool the worker may call. `[a-z0-9_]`.
        public var tool: String
        /// Seconds Codex waits for one tool call.
        public var toolTimeout: Int
        public init(name: String, command: String, arguments: [String], tool: String, toolTimeout: Int) {
            self.name = name; self.command = command; self.arguments = arguments; self.tool = tool; self.toolTimeout = toolTimeout
        }
    }

    /// Codex features with tools that act outside the OS sandbox. Off in staged runs.
    /// Checked against codex-cli 0.160.0 (`codex features list`, and a tool-catalogue probe with these off).
    public static let remoteToolFeatures = ["apps", "browser_use", "browser_use_external", "browser_use_full_cdp_access",
                                            "computer_use", "in_app_browser", "image_generation", "plugins", "remote_plugin",
                                            "skill_search", "skill_mcp_dependency_install", "goals"]
    /// Codex features that run commands. Off for a worker whose only tool is a fixed server.
    public static let commandToolFeatures = ["shell_tool", "unified_exec", "unified_exec_tty", "shell_snapshot"]

    /// The full launch for one agent turn. `cliPath` is the resolved CLI from settings.
    /// `resumeSession` continues a session this run created (ask mode).
    public static func agent(_ task: AgentTask, cliPath: String, prompt: String, schema: String, files: Files,
                             resumeSession: String? = nil, baseEnvironment: [String: String], path: String,
                             options: Options = Options()) throws -> ProcessLaunch {
        guard cliPath.hasPrefix("/") else { throw RunnerCommandError.cliMissing(task.runner) }
        if let resumeSession, UUID(uuidString: resumeSession) == nil { throw RunnerCommandError.invalidSession }
        // The CLI's own folder first: a Node-based CLI needs `node` beside it.
        let cliDir = URL(fileURLWithPath: cliPath).deletingLastPathComponent().path
        let env = environment(base: baseEnvironment, path: ([cliDir] + path.split(separator: ":").map(String.init).filter { $0 != cliDir }).joined(separator: ":"))
        let args: [String]
        switch task.runner {
        case .codex: args = codexArguments(task, schemaFile: files.schemaFile, lastMessage: files.lastMessageFile, resume: resumeSession,
                                           options: options)
        case .claude: args = claudeArguments(task, schema: schema, resume: resumeSession, settingsFile: files.claudeSettingsFile)
        }
        return ProcessLaunch(executable: cliPath, arguments: args, environment: env,
                             workingDirectory: task.workingDirectory, stdin: Data(prompt.utf8))
    }

    static func effortValue(_ effort: ReasoningEffort) -> String? { effort == .none ? nil : effort.rawValue }

    /// Codex features that start more agents from inside a run. Both stay off, so a run has exactly the workers Jevcast starts.
    public static let disabledCodexFeatures = ["multi_agent", "multi_agent_v2"]

    static func codexArguments(_ task: AgentTask, schemaFile: URL, lastMessage: URL, resume: String?,
                               options: Options = Options()) -> [String] {
        let sandbox = task.access == .readOnly ? "read-only" : "workspace-write"
        var a = ["exec"]
        if resume != nil { a.append("resume") }
        a += ["--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json"]
        if resume == nil, options.ephemeral { a.append("--ephemeral") }
        for feature in disabledCodexFeatures { a += ["-c", "features.\(feature)=false"] }
        if resume == nil {
            a += ["-s", sandbox]
        } else {
            // `exec resume` has no -s, -C or --add-dir; the same limits go in as config overrides,
            // and the process working folder is the task's folder.
            a += ["-c", "sandbox_mode=\"\(sandbox)\""]
            if task.access.canWrite { a += ["-c", "sandbox_workspace_write.writable_roots=\(tomlArray(task.allowedRoots))"] }
        }
        a += ["-m", AgentModelCatalog.resolved(task.model, runner: .codex)]
        if let e = effortValue(task.effort) { a += ["-c", "model_reasoning_effort=\"\(e)\""] }
        if task.fast && AgentModelCatalog.supportsFast(.codex) { a += ["-c", "service_tier=\"fast\""] }
        if task.access.usesNetwork { a += ["-c", "sandbox_workspace_write.network_access=true"] }
        if task.access.canWrite, options.excludeTemporaryFolders {
            a += ["-c", "sandbox_workspace_write.exclude_slash_tmp=true", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true"]
        }
        if options.noRemoteTools {
            for feature in remoteToolFeatures { a += ["-c", "features.\(feature)=false"] }
            a += ["-c", "web_search=\"disabled\""]
        }
        if let server = options.toolServer {
            for feature in commandToolFeatures { a += ["-c", "features.\(feature)=false"] }
            let key = "mcp_servers.\(server.name)"
            a += ["-c", "\(key).command=\(tomlString(server.command))", "-c", "\(key).args=\(tomlArray(server.arguments))",
                  "-c", "\(key).startup_timeout_sec=20", "-c", "\(key).tool_timeout_sec=\(max(30, server.toolTimeout))"]
            // Only the one saved tool is offered, and only it is pre-approved. Codex exec cannot ask, so an
            // unapproved call would fail; no other tool or server gains approval.
            a += ["-c", "\(key).enabled_tools=\(tomlArray([server.tool]))",
                  "-c", "\(key).default_tools_approval_mode=\"prompt\"",
                  "-c", "\(key).tools.\(server.tool).approval_mode=\"approve\""]
        }
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
        // Claude has no fast tier; `task.fast` is never sent.
        a += ["--model", AgentModelCatalog.resolved(task.model, runner: .claude)]
        if let e = effortValue(task.effort) { a += ["--effort", e] }
        for root in task.allowedRoots { a += ["--add-dir", root] }
        if let settingsFile { a += ["--settings", settingsFile.path] }
        if let resume { a += ["--resume", resume] }
        return a
    }

    /// One TOML basic string.
    static func tomlString(_ value: String) -> String {
        String(tomlArray([value]).dropFirst().dropLast())
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
