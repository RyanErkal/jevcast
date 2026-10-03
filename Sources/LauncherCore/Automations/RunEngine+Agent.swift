import Foundation

extension RunEngine {
    static let schemaFile = "schema.json"
    static let lastMessageFile = "last-message.txt"
    public static let proposalRawFile = "proposal-raw.json"

    /// One agent turn: a fresh prompt, a resumed session with an answer or revision note, or a diagnosis report.
    static let cliUpdatedNote = "CLI updated since last run"

    func runAgent(_ run: inout RunRecord, _ task: AgentTask, automation: Automation, control: RunControl,
                  followUp: RunFollowUp?, diagnosis: String?) -> Step {
        let step = runAgentTurn(&run, task, automation: automation, control: control, followUp: followUp, diagnosis: diagnosis)
        // A changed CLI never blocks (CLIs update themselves); the run only says so.
        let cli = task.runner == .codex ? context.settings.codexPath : context.settings.claudePath
        if let approved = automation.approvedAgentCLI, !approved.matches(ProgramIdentity.read(path: cli, hash: false)) {
            if run.summary.isEmpty, case .done(_, let error?) = step { run.summary = String(error.prefix(200)) }
            if !run.summary.contains(Self.cliUpdatedNote) {
                run.summary = run.summary.isEmpty ? Self.cliUpdatedNote : run.summary + " (\(Self.cliUpdatedNote))"
            }
        }
        return step
    }

    private func runAgentTurn(_ run: inout RunRecord, _ task: AgentTask, automation: Automation, control: RunControl,
                              followUp: RunFollowUp?, diagnosis: String?) -> Step {
        if task.access.canWrite {
            let controlPath = store.root.resolvingSymlinksInPath().path
            let roots = [task.workingDirectory] + task.allowedRoots
            for root in roots {
                let path = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                guard let parts = SafeFS.components(SafeFS.folded(path)),
                      let control = SafeFS.components(SafeFS.folded(controlPath)),
                      !SafeFS.isInside(control, parts), !SafeFS.isInside(parts, control) else {
                    return .done(.failed, "The agent's writable folders must not include automation state.")
                }
            }
        }
        let mode: OutputMode = diagnosis != nil ? .report : task.output
        let prompt: String
        var resume: String?
        switch followUp {
        case .none:
            let body = diagnosis.map { task.prompt + "\n\n" + $0 } ?? task.prompt
            prompt = AgentPrompt.wrap(body, automationName: automation.name, mode: mode)
        case .answer(let round, let text)?:
            guard let index = run.questions.firstIndex(where: { $0.round == round && $0.answer == nil }) else {
                return .done(.failed, "No open question for round \(round).")
            }
            run.questions[index].answer = text
            resume = run.sessionID
            prompt = AgentPrompt.answer(text, round: round)
        case .revise(let note)?:
            guard mode == .proposal else { return .done(.failed, "Only a proposal can be revised.") }
            resume = run.sessionID
            prompt = AgentPrompt.revise(note)
        }
        if followUp != nil, resume == nil { return .done(.failed, "This run has no session to continue. Start a new run.") }

        let turn: AgentTurn
        switch launchAgentTurn(&run, task: task, prompt: prompt, schema: AgentPrompt.schema(mode), resume: resume,
                               options: RunnerCommand.Options(ephemeral: mode == .report && followUp == nil),
                               timeout: TimeInterval(automation.policy.timeout), control: control) {
        case .failure(let step): return step
        case .success(let t): turn = t
        }
        switch turn.outcome.reason {
        case .spawnFailed(let why): return .retry(why, spawnOnly: true)
        case .identityNotSaved: return .done(.failed, Self.identityNotSaved)
        case .cancelled: return .done(.cancelled, "Cancelled.")
        case .timedOut: return .done(.failed, "Stopped after \(automation.policy.timeout) seconds.")
        case .signaled, .exited: break
        }
        if let failure = turn.failure {
            return Self.isTransient(failure) ? .retry(failure, spawnOnly: false) : .done(.failed, String(failure.prefix(1000)))
        }
        guard let structured = turn.structured else { return .done(.failed, "The agent finished without a reply.") }
        let output: AgentOutput
        do { output = try AgentOutput.parse(structured, mode: mode) } catch { return .done(.failed, "\(error)") }
        return store(output, into: &run, raw: structured, diagnosis: diagnosis != nil)
    }

    /// What one CLI turn left: how it ended, its events, its structured reply, and a failure text when it failed.
    enum TurnResult { case success(AgentTurn), failure(Step) }

    struct AgentTurn {
        var outcome: ProcessOutcome
        var events: RunnerEvents
        var structured: Data?
        /// Redacted CLI error or stderr when the CLI reported an error or exited non-zero.
        var failure: String?
    }

    /// Starts one CLI turn and waits for it. Checks the subscription sign-in first for Codex, writes the
    /// schema beside the run, and keeps the Claude sign-in copy only while the CLI runs. `fileTag` keeps
    /// the files of several turns in one run apart.
    func launchAgentTurn(_ run: inout RunRecord, task: AgentTask, prompt: String, schema: String, resume: String?,
                         options: RunnerCommand.Options, timeout: TimeInterval, control: RunControl,
                         fileTag: String = "") -> TurnResult {
        if task.runner == .codex, case .problem(let why) = CodexAuth.check(home: context.baseEnvironment["HOME"] ?? NSHomeDirectory()) {
            return .failure(.done(.failed, why))
        }
        let cli = task.runner == .codex ? context.settings.codexPath : context.settings.claudePath
        let folder = store.runFolder(automationID: run.automationID, runID: run.id)
        let schemaName = fileTag.isEmpty ? Self.schemaFile : fileTag + "-" + Self.schemaFile
        let lastName = fileTag.isEmpty ? Self.lastMessageFile : fileTag + "-" + Self.lastMessageFile
        do {
            try store.writeRunFile(automationID: run.automationID, runID: run.id, name: schemaName, data: Data(schema.utf8))
            if task.runner == .codex {
                try store.writeRunFile(automationID: run.automationID, runID: run.id, name: lastName, data: Data())
            }
        } catch { return .failure(.done(.failed, "The run folder could not be written: \(error)")) }
        var signInFile: URL?
        if task.runner == .claude, context.settings.claudeUsesSettingsSignIn {
            guard let env = ClaudeSignIn.gatewayEnvironment(), let data = ClaudeSignIn.settingsData(env) else {
                return .failure(.done(.failed, "Claude is set to sign in through ~/.claude/settings.json, but no gateway is set there."))
            }
            do { try store.writeRunFile(automationID: run.automationID, runID: run.id, name: ClaudeSignIn.fileName, data: data) }
            catch { return .failure(.done(.failed, "The run folder could not be written: \(error)")) }
            signInFile = folder.appendingPathComponent(ClaudeSignIn.fileName)
        }
        // The sign-in copy holds a token, so it lives only while the CLI runs.
        defer { if let signInFile { try? FileManager.default.removeItem(at: signInFile) } }
        let files = RunnerCommand.Files(schemaFile: folder.appendingPathComponent(schemaName),
                                        lastMessageFile: folder.appendingPathComponent(lastName),
                                        claudeSettingsFile: signInFile)
        let launch: ProcessLaunch
        do {
            launch = try RunnerCommand.agent(task, cliPath: cli, prompt: prompt, schema: schema, files: files, resumeSession: resume,
                                             baseEnvironment: context.baseEnvironment, path: context.settings.scriptPath, options: options)
        } catch { return .failure(.done(.failed, "\(error)")) }

        let box = EventBox(runner: task.runner)
        let outcome = supervise(&run, control.supervisor(killGrace: context.killGrace), launch, timeout: timeout) { box.consume($0) }
        let events = box.value
        if let u = events.usage { run.usage = (run.usage ?? TokenUsage()) + u }
        if let s = events.sessionID, UUID(uuidString: s) != nil { run.sessionID = s }
        run.exitCode = outcome.exitCode
        if !fileTag.isEmpty, !outcome.stderrTail.isEmpty {
            let text = Redactor.redact(Redactor.tail(outcome.stderrTail, maxBytes: Self.stderrBytes))
            try? store.writeRunFile(automationID: run.automationID, runID: run.id, name: fileTag + "-stderr.txt", data: Data(text.utf8))
        }
        var failure: String?
        if outcome.reason == .exited || outcome.reason == .signaled, !outcome.succeeded || events.error != nil {
            let stderr = Redactor.redact(Redactor.tail(outcome.stderrTail, maxBytes: 2000)).trimmingCharacters(in: .whitespacesAndNewlines)
            failure = Redactor.redact(events.error ?? (stderr.isEmpty ? "The \(task.runner.executableName) CLI exited with code \(outcome.exitCode ?? -1)." : stderr))
        }
        var structured = events.structured
        if structured == nil, task.runner == .codex,
           let data = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: lastName), !data.isEmpty {
            structured = data
        }
        return .success(AgentTurn(outcome: outcome, events: events, structured: structured, failure: failure))
    }

    private func store(_ output: AgentOutput, into run: inout RunRecord, raw: Data, diagnosis: Bool) -> Step {
        switch output {
        case .report(let summary, let markdown):
            var text = markdown
            if diagnosis {
                let previous = store.readOutput(run) ?? ""
                text = "## Diagnosis\n\n" + markdown + "\n\n## Script output\n\n" + previous
            }
            guard writeOutput(&run, text) else { return .done(.failed, "The report could not be saved.") }
            run.summary = summary
            return .done(.succeeded, nil)
        case .question(let summary, let markdown, let question, let choices):
            let asked = run.questions.count
            guard asked < Self.maxQuestionRounds else { return .done(.failed, "The agent asked more than \(Self.maxQuestionRounds) questions.") }
            if !markdown.isEmpty, !writeOutput(&run, markdown) { return .done(.failed, "The output could not be saved.") }
            run.questions.append(RunQuestion(round: asked + 1, text: question, choices: choices))
            run.summary = summary.isEmpty ? question : summary
            return .done(.needsInput, nil)
        case .proposal(let proposal):
            // Saved in the `Proposal` format the app's validator reads, not the agent's schema shape
            // (which uses empty strings for unused fields and has no version).
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try store.writeRunFile(automationID: run.automationID, runID: run.id, name: Self.proposalRawFile, data: encoder.encode(proposal))
            } catch { return .done(.failed, "The proposal could not be saved.") }
            run.proposalFile = Self.proposalRawFile
            run.summary = proposal.summary.isEmpty ? "\(proposal.items.count) changes to review" : proposal.summary
            _ = writeOutput(&run, proposal.summary)
            return .done(.needsApproval, nil)
        }
    }

    /// Network trouble and provider overload. Auth, policy and validation errors are not transient.
    static func isTransient(_ text: String) -> Bool {
        let t = text.lowercased()
        let hints = ["network", "connection reset", "connection refused", "timed out", "timeout", "econnreset", "etimedout",
                     "rate limit", "429", "502", "503", "504", "overloaded", "temporarily unavailable", "stream disconnected"]
        let blockers = ["auth", "login", "log in", "permission", "invalid", "not found", "unsupported"]
        return hints.contains(where: t.contains) && !blockers.contains(where: t.contains)
    }
}

/// Collects events from the stdout thread.
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: RunnerEvents
    init(runner: AgentRunner) { events = RunnerEvents(runner: runner) }
    func consume(_ line: Data) { lock.lock(); events.consume(line); lock.unlock() }
    var value: RunnerEvents { lock.lock(); defer { lock.unlock() }; return events }
}
