import Foundation

extension RunEngine {
    static let schemaFile = "schema.json"
    static let lastMessageFile = "last-message.txt"
    public static let proposalRawFile = "proposal-raw.json"

    /// One agent turn: a fresh prompt, a resumed session with an answer or revision note, or a diagnosis report.
    func runAgent(_ run: inout RunRecord, _ task: AgentTask, automation: Automation, control: RunControl,
                  followUp: RunFollowUp?, diagnosis: String?) -> Step {
        let mode: OutputMode = diagnosis != nil ? .report : task.output
        let cli = task.runner == .codex ? context.settings.codexPath : context.settings.claudePath
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

        let folder = store.runFolder(automationID: run.automationID, runID: run.id)
        let schema = AgentPrompt.schema(mode)
        do {
            try store.writeRunFile(automationID: run.automationID, runID: run.id, name: Self.schemaFile, data: Data(schema.utf8))
        } catch { return .done(.failed, "The run folder could not be written: \(error)") }
        var signInFile: URL?
        if task.runner == .claude, context.settings.claudeUsesSettingsSignIn {
            guard let env = ClaudeSignIn.gatewayEnvironment(), let data = ClaudeSignIn.settingsData(env) else {
                return .done(.failed, "Claude is set to sign in through ~/.claude/settings.json, but no gateway is set there.")
            }
            do { try store.writeRunFile(automationID: run.automationID, runID: run.id, name: ClaudeSignIn.fileName, data: data) }
            catch { return .done(.failed, "The run folder could not be written: \(error)") }
            signInFile = folder.appendingPathComponent(ClaudeSignIn.fileName)
        }
        // The sign-in copy holds a token, so it lives only while the CLI runs.
        defer { if let signInFile { try? FileManager.default.removeItem(at: signInFile) } }
        let files = RunnerCommand.Files(schemaFile: folder.appendingPathComponent(Self.schemaFile),
                                        lastMessageFile: folder.appendingPathComponent(Self.lastMessageFile),
                                        claudeSettingsFile: signInFile)
        let launch: ProcessLaunch
        do {
            launch = try RunnerCommand.agent(task, cliPath: cli, prompt: prompt, schema: schema, files: files, resumeSession: resume,
                                             baseEnvironment: context.baseEnvironment, path: context.settings.scriptPath)
        } catch { return .done(.failed, "\(error)") }

        let events = EventBox(runner: task.runner)
        let outcome = control.supervisor(killGrace: context.killGrace).run(launch, timeout: TimeInterval(automation.policy.timeout)) { events.consume($0) }
        let parsed = events.value
        if let u = parsed.usage { run.usage = (run.usage ?? TokenUsage()) + u }
        if let s = parsed.sessionID, UUID(uuidString: s) != nil { run.sessionID = s }
        run.exitCode = outcome.exitCode

        switch outcome.reason {
        case .spawnFailed(let why): return .retry(why, spawnOnly: true)
        case .cancelled: return .done(.cancelled, "Cancelled.")
        case .timedOut: return .done(.failed, "Stopped after \(automation.policy.timeout) seconds.")
        case .signaled, .exited: break
        }
        let stderr = Redactor.redact(Redactor.tail(outcome.stderrTail, maxBytes: 2000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard outcome.succeeded, parsed.error == nil else {
            let why = parsed.error ?? (stderr.isEmpty ? "The \(task.runner.executableName) CLI exited with code \(outcome.exitCode ?? -1)." : stderr)
            return Self.isTransient(why) ? .retry(why, spawnOnly: false) : .done(.failed, String(why.prefix(1000)))
        }
        var structured = parsed.structured
        if structured == nil, task.runner == .codex,
           let data = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: Self.lastMessageFile) {
            structured = data
        }
        guard let structured else { return .done(.failed, "The agent finished without a reply.") }
        let output: AgentOutput
        do { output = try AgentOutput.parse(structured, mode: mode) } catch { return .done(.failed, "\(error)") }
        return store(output, into: &run, raw: structured, diagnosis: diagnosis != nil)
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
