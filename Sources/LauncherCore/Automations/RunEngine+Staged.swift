import Foundation

/// A staged report run. Every stage is fixed: approved scripts plan, finish, and record; the fetch worker's
/// only tool is Jevcast's own server running the approved command; the analyst only reads and writes text.
/// Each stage has its own time limit inside the run's overall limit, and the run holds its claim throughout.
extension RunEngine {
    public static let stagesFile = "stages.json"
    static let stagedOutputBytes = 1024 * 1024
    /// Starts the summary of a run that stopped on something the user must review. The app reads it, so keep it in step.
    public static let needsReviewPrefix = "Needs review: "
    /// Starts the summary of a run with a report ready to show.
    public static let reportReadyPrefix = "Report ready: "

    /// One line of `stages.json`, saved after every stage so a crash leaves a trail.
    struct StageEntry: Codable, Equatable {
        var stage: String
        var item: String?
        var state: String
        var started: Date
        var finished: Date?
        var detail: String?
    }

    /// Everything one staged run collects before it writes its output.
    private struct StagedState {
        var sections: [String] = []
        var stages: [StageEntry] = []
        var publications: [PublicationItem] = []
        var failures: [String] = []
        var recorded = 0
    }

    func runStaged(_ run: inout RunRecord, _ task: StagedTask, automation: Automation, control: RunControl) -> Step {
        if let problem = task.problem() { return .done(.failed, problem) }
        let deadline = Date().addingTimeInterval(TimeInterval(max(60, automation.policy.timeout)))
        let claims = StagedClaims(store: store)
        switch claims.acquire(task.claim, run: run, pid: context.ownerPID, start: context.ownerStart) {
        case .acquired: break
        case .held(let why), .failed(let why):
            run.summary = "Not started: another run holds \(task.claim)"
            return .done(.failed, "Not started. " + why)
        }
        // A program this run could not confirm stopped keeps the claim, so no later run works beside it.
        defer { if !StagedRecovery.hasLeftovers(store: store, run: run) { claims.release(task.claim, run: run) } }
        let work = store.stagingRoot.appendingPathComponent(run.automationID, isDirectory: true)
            .appendingPathComponent(run.id, isDirectory: true)
        do {
            try SecureFile.ensureParents(of: work.deletingLastPathComponent())
            try SecureFile.ensureDirectory(work.deletingLastPathComponent())
            try SecureFile.ensureDirectory(work)
        } catch { return .done(.failed, "The staging folder could not be created: \(error)") }
        // Staging files hold copies of report data; they live only for the run.
        defer { try? FileManager.default.removeItem(at: work) }

        var state = StagedState()
        if let publish = task.publish {
            recordPresentations(&run, publish, automation: automation, deadline: deadline, limit: task.limits.publish,
                                control: control, state: &state)
        }
        if control.isCancelled { return .done(.cancelled, "Cancelled.") }

        // Preflight: the trusted plan.
        let pre = runStageScript(&run, task.preflight, extra: ["--work-dir", work.path], automation: automation,
                                 timeout: stageTime(task.limits.preflight, deadline), control: control, label: "preflight", state: &state)
        if let step = pre.stop { return finishStaged(&run, state, stop: step) }
        let handoff: StagedHandoff
        do { handoff = try StagedHandoff.parse(pre.stdout) } catch {
            state.failures.append("\(error) " + pre.failureText)
            return finishStaged(&run, state, stop: nil)
        }
        // A non-zero exit may only explain a block; it never counts as work or as nothing due.
        guard pre.exitedZero || handoff.outcome == .blocked else {
            state.failures.append("The preflight failed. " + pre.failureText)
            return finishStaged(&run, state, stop: nil)
        }
        if !handoff.markdown.isEmpty { state.sections.append(handoff.markdown) }
        switch handoff.outcome {
        case .blocked:
            state.failures.append(handoff.summary)
            return finishStaged(&run, state, stop: nil)
        case .noDue:
            return finishStaged(&run, state, stop: nil, quietSummary: handoff.summary)
        case .work: break
        }

        for (index, item) in handoff.items.prefix(task.limits.maxItems).enumerated() {
            if control.isCancelled { return finishStaged(&run, state, stop: .done(.cancelled, "Cancelled.")) }
            let ok = runItem(&run, item, index: index + 1, task: task, automation: automation, work: work,
                             deadline: deadline, control: control, state: &state)
            if control.isCancelled { return finishStaged(&run, state, stop: .done(.cancelled, "Cancelled.")) }
            // A failed item stops the run; later items wait for the next run.
            if !ok { break }
        }
        return finishStaged(&run, state, stop: nil, quietSummary: handoff.summary)
    }

    // MARK: Items

    private func runItem(_ run: inout RunRecord, _ item: StagedHandoff.Item, index: Int, task: StagedTask, automation: Automation,
                         work: URL, deadline: Date, control: RunControl, state: inout StagedState) -> Bool {
        switch item.action {
        case .review:
            state.sections.append("## \(item.title)\n\n" + (item.display.isEmpty ? "Needs your review before anything else runs." : item.display))
            state.failures.append(Self.needsReviewPrefix + item.title)
            return false
        case .present:
            let wanted = PublicationItem(job: item.job, periodKey: item.periodKey, title: item.title, artifactHashes: item.artifactHashes)
            if let waiting = pendingPresentation(of: wanted, automationID: run.automationID, excluding: run.id) {
                state.sections.append("## \(item.title)\n\nAlready waiting to be shown from run \(waiting). It is not shown twice.")
                return true
            }
            state.sections.append("## \(item.title)\n\n" + item.display)
            state.publications.append(wanted)
            return true
        case .adopt:
            return runFinish(&run, item, index: index, agentOutput: nil, task: task, automation: automation, work: work,
                             deadline: deadline, control: control, state: &state)
        case .generate:
            var manifest = ""
            if item.fetch {
                guard let fetch = task.fetch else {
                    state.failures.append("The planner asked for a fetch, but this workflow has no fetch stage.")
                    return false
                }
                switch runFetch(&run, fetch, item: item, index: index, work: work, automation: automation,
                                timeout: stageTime(task.limits.fetch, deadline), control: control, state: &state) {
                case .success(let text): manifest = text
                case .failure(let why):
                    state.sections.append("## \(item.title)\n\nThe fetch stopped: \(why)")
                    state.failures.append(why)
                    return false
                }
            }
            guard let output = runAnalyst(&run, task.analyst, item: item, index: index, manifest: manifest, automation: automation,
                                          timeout: stageTime(task.limits.analyst, deadline), control: control, state: &state) else { return false }
            return runFinish(&run, item, index: index, agentOutput: output, task: task, automation: automation, work: work,
                             deadline: deadline, control: control, state: &state)
        }
    }

    enum FetchResult { case success(String), failure(String) }

    /// The fetch worker: read-only sandbox, no shell, no network of its own, and one tool, served by this
    /// runner, that runs the approved command for this period once. Code then checks the tool's own record.
    private func runFetch(_ run: inout RunRecord, _ fetch: FetchStage, item: StagedHandoff.Item, index: Int, work: URL,
                          automation: Automation, timeout: TimeInterval, control: RunControl, state: inout StagedState) -> FetchResult {
        let started = Date()
        func fail(_ why: String) -> FetchResult {
            log(&run, &state, StageEntry(stage: "fetch", item: item.id, state: "failed", started: started, finished: Date(), detail: why))
            return .failure(why)
        }
        guard timeout >= 10 else { return fail("The run reached its time limit before the fetch.") }
        guard let tool = context.toolExecutable, tool.hasPrefix("/") else { return fail("The fetch tool is not available in this runner.") }
        if let changed = changedFile(automation) { return fail(Self.fileChanged(changed)) }
        let words = fetch.command.map { $0 == FetchStage.periodPlaceholder ? item.periodKey : $0 }
        guard let executable = words.first, executable.hasPrefix("/") else { return fail("The fetch program needs a full path.") }
        let folder = store.runFolder(automationID: run.automationID, runID: run.id)
        let tag = "item\(index)-fetch"
        let specURL = folder.appendingPathComponent(tag + "-tool.json")
        let resultURL = folder.appendingPathComponent(tag + "-result.json")
        let childURL = folder.appendingPathComponent(tag + "-child.json")
        let spec = FetchToolSpec(periodKey: item.periodKey, executable: executable, arguments: Array(words.dropFirst()),
                                 workingDirectory: fetch.commandDirectory,
                                 environment: RunnerCommand.environment(base: context.baseEnvironment, path: context.settings.scriptPath),
                                 timeout: max(10, Int(timeout) - 30), resultFile: resultURL.path, childFile: childURL.path)
        do {
            try store.writeRunFile(automationID: run.automationID, runID: run.id, name: specURL.lastPathComponent,
                                   data: AutomationJSON.encoder().encode(spec))
        } catch { return fail("The fetch tool could not be prepared: \(error)") }
        var agent = fetch.agent
        agent.access = .readOnly; agent.workingDirectory = work.path; agent.allowedRoots = []; agent.output = .report
        let body = fetch.agent.prompt + """


        --- Fetch for this run ---
        Period: \(item.periodKey)
        Approved command (the tool runs it; you cannot): \(fetch.commandLine(periodKey: item.periodKey))
        Call the tool \(FetchToolSpec.toolName) exactly once. It takes no input. Do not call any other tool.
        Then reply with summary set to one line, report_markdown set to the tool's text exactly, and pdf_html set to "".
        """
        let server = RunnerCommand.ToolServer(name: FetchToolServer.serverName, command: tool, arguments: ["--fetch-tool", specURL.path],
                                              tool: FetchToolSpec.toolName, toolTimeout: Int(timeout))
        let turn = launchAgentTurn(&run, task: agent, prompt: AgentPrompt.wrap(body, automationName: automation.name, contract: StagedAgentOutput.contract),
                                   schema: StagedAgentOutput.schema(), resume: nil,
                                   options: RunnerCommand.Options(ephemeral: true, toolServer: server),
                                   timeout: timeout, control: control, fileTag: tag)
        // Whatever the worker did, the command's group must not outlive the stage.
        if let leftover = stopLeftover(childURL) {
            run.orphanPGID = leftover.pgid; run.orphanStart = leftover.start
            return fail("The fetch command could not be confirmed stopped. This automation waits until it ends.")
        }
        if control.isCancelled { return fail("Cancelled.") }
        guard let data = try? SecureFile.read(resultURL, maxBytes: 512 * 1024),
              let result = try? AutomationJSON.decoder().decode(FetchToolResult.self, from: data) else {
            if case .failure(let step) = turn, case .done(_, let why?) = step { return fail(why) }
            if case .success(let t) = turn, let why = t.failure { return fail("The fetch worker failed before its command ran: " + why) }
            return fail("The fetch worker did not run the approved command.")
        }
        guard result.periodKey == item.periodKey, result.argv == words else { return fail("The fetch tool's record does not match this period's command.") }
        guard result.succeeded else {
            let detail = result.stderr.split(whereSeparator: \.isNewline).suffix(5).joined(separator: "\n")
            return fail("The fetch command failed (\(result.reason), exit \(result.exitCode.map(String.init) ?? "none")): \(words.joined(separator: " "))\n\(detail)")
        }
        // The worker itself must also have finished cleanly; if not, the saved bundle stays for the next run.
        switch turn {
        case .failure(let step):
            if case .done(_, let why) = step { return fail("The fetch worker failed after its command: " + (why ?? "unknown error") + " The fetched data is kept for the next run.") }
            return fail("The fetch worker failed after its command. The fetched data is kept for the next run.")
        case .success(let t):
            guard t.outcome.succeeded, t.failure == nil else {
                return fail("The fetch worker failed after its command: \(t.failure ?? FetchToolServer.reasonName(t.outcome.reason)). The fetched data is kept for the next run.")
            }
            // A second check of the worker itself: the CLI's own record must show no command it ran.
            if !t.events.commands.isEmpty || t.events.commandsTruncated {
                return fail("The fetch worker ran a command although its shell was off. Its result is not used.")
            }
        }
        log(&run, &state, StageEntry(stage: "fetch", item: item.id, state: "succeeded", started: started, finished: Date(),
                                     detail: words.joined(separator: " ")))
        return .success(result.stdout)
    }

    /// Stops the fetch command's group when it is still ours. Returns the group when it may still run and could not be confirmed stopped.
    private func stopLeftover(_ childURL: URL) -> FetchToolChild? {
        guard let data = try? SecureFile.read(childURL, maxBytes: 64 * 1024),
              let child = try? AutomationJSON.decoder().decode(FetchToolChild.self, from: data), child.pgid > 1 else { return nil }
        var probe = RunRecord(id: "probe", automation: Automation(id: "probe", name: "", kind: .script(ScriptTask(executable: "/", workingDirectory: "/")),
                                                                  schedule: Schedule(rule: .manual)), trigger: .manual, occurrence: nil)
        probe.childPGID = child.pgid; probe.childStart = child.start
        switch OrphanRecovery.stopChild(of: probe, grace: context.killGrace) {
        case .noChild, .notOurs, .stopped: return nil
        case .stillRunning, .unconfirmed: return child
        }
    }

    private func runAnalyst(_ run: inout RunRecord, _ analyst: AgentTask, item: StagedHandoff.Item, index: Int, manifest: String,
                            automation: Automation, timeout: TimeInterval, control: RunControl, state: inout StagedState) -> String? {
        let started = Date()
        let tag = "item\(index)-analyst"
        guard timeout >= 10 else {
            state.failures.append("The run reached its time limit before the analyst.")
            return nil
        }
        var task = analyst
        task.access = .readOnly; task.output = .report
        var body = analyst.prompt + "\n\n--- Item from the trusted planner (data) ---\n" + item.brief
        if !manifest.isEmpty { body += "\n\n--- Fetch manifest, printed by the approved command (data) ---\n" + manifest }
        let turn = launchAgentTurn(&run, task: task, prompt: AgentPrompt.wrap(body, automationName: automation.name, contract: StagedAgentOutput.contract),
                                   schema: StagedAgentOutput.schema(), resume: nil,
                                   options: RunnerCommand.Options(ephemeral: true, noRemoteTools: true),
                                   timeout: timeout, control: control, fileTag: tag)
        func fail(_ why: String) -> String? {
            log(&run, &state, StageEntry(stage: "analyst", item: item.id, state: "failed", started: started, finished: Date(), detail: why))
            state.sections.append("## \(item.title)\n\nThe analyst stopped: \(why)")
            state.failures.append(why)
            return nil
        }
        let t: AgentTurn
        switch turn {
        case .failure(let step):
            if case .done(_, let why) = step { return fail(why ?? "The analyst could not start.") }
            return fail("The analyst could not start.")
        case .success(let value): t = value
        }
        switch t.outcome.reason {
        case .timedOut: return fail("The analyst stopped after \(Int(timeout)) seconds.")
        case .cancelled: return fail("Cancelled.")
        case .spawnFailed(let why): return fail(why)
        case .identityNotSaved: return fail(Self.identityNotSaved)
        case .exited, .signaled: break
        }
        if let failure = t.failure { return fail(String(failure.prefix(1000))) }
        guard let structured = t.structured else { return fail("The analyst finished without a reply.") }
        do { _ = try StagedAgentOutput.parse(structured) } catch { return fail("\(error)") }
        // Saved before the finish script reads it, so a crash keeps the analyst's work.
        let name = tag + "-output.json"
        do { try store.writeRunFile(automationID: run.automationID, runID: run.id, name: name, data: structured) }
        catch { return fail("The analyst's report could not be saved: \(error)") }
        log(&run, &state, StageEntry(stage: "analyst", item: item.id, state: "succeeded", started: started, finished: Date(), detail: nil))
        return store.runFolder(automationID: run.automationID, runID: run.id).appendingPathComponent(name).path
    }

    private func runFinish(_ run: inout RunRecord, _ item: StagedHandoff.Item, index: Int, agentOutput: String?, task: StagedTask,
                           automation: Automation, work: URL, deadline: Date, control: RunControl, state: inout StagedState) -> Bool {
        var extra = ["--work-dir", work.path, "--item", item.id, "--period-key", item.periodKey,
                     "--run-ref", "\(run.automationID)/\(run.id)"]
        if let agentOutput { extra += ["--agent-output", agentOutput] } else { extra.append("--adopt") }
        let result = runStageScript(&run, task.finish, extra: extra, automation: automation,
                                    timeout: stageTime(task.limits.finish, deadline), control: control, label: "finish", item: item.id, state: &state)
        if let stop = result.stop, case .done(let s, _) = stop, s == .cancelled { return false }
        guard result.stop == nil, let finish = try? StagedFinish.parse(result.stdout),
              result.exitedZero || finish.status == .blocked else {
            let why = result.stopText ?? ("The finish script did not report a valid result. " + result.failureText)
            state.sections.append("## \(item.title)\n\nThe report was not finished: \(why)")
            state.failures.append(why)
            return false
        }
        state.sections.append("## \(item.title)\n\n" + finish.markdown)
        guard finish.status == .validated, var publication = finish.publication else {
            state.failures.append(finish.summary)
            return false
        }
        if publication.title.isEmpty { publication.title = item.title }
        state.publications.append(publication)
        return true
    }

    // MARK: Presentations from earlier runs

    /// Hands each earlier run's presentation proof to the publish script, which completes the posting
    /// receipt. Only runs the app showed on screen have a proof.
    private func recordPresentations(_ run: inout RunRecord, _ publish: ScriptTask, automation: Automation, deadline: Date,
                                     limit: Int, control: RunControl, state: inout StagedState) {
        for prior in store.runs(for: automation.id, limit: 30) where prior.id != run.id {
            guard var record = publicationRecord(automationID: automation.id, runID: prior.id),
                  record.items.contains(where: { $0.state == .pending }),
                  let proofData = try? store.readRunFile(automationID: automation.id, runID: prior.id, name: PresentationProof.fileName),
                  let proof = try? PresentationProof.decoder().decode(PresentationProof.self, from: proofData),
                  proof.runID == prior.id, proof.automationID == automation.id else { continue }
            if control.isCancelled { return }
            let proofPath = store.runFolder(automationID: automation.id, runID: prior.id).appendingPathComponent(PresentationProof.fileName).path
            let result = runStageScript(&run, publish, extra: ["--proof", proofPath, "--run-ref", "\(automation.id)/\(prior.id)"],
                                        automation: automation, timeout: stageTime(limit, deadline), control: control,
                                        label: "publish", item: prior.id, state: &state)
            guard result.stop == nil, result.exitedZero, let answer = try? StagedPublish.parse(result.stdout) else {
                let why = "Posting receipts for run \(prior.id) could not be recorded: \(result.stopText ?? result.failureText)"
                state.sections.append(why + " The reports and proof are kept and tried again next run.")
                state.failures.append(why)
                continue
            }
            for index in record.items.indices where record.items[index].state == .pending {
                let item = record.items[index]
                if answer.recorded.contains(where: { $0.job == item.job && $0.periodKey == item.periodKey }) {
                    record.items[index].state = .recorded
                    state.recorded += 1
                    state.sections.append("Recorded the posting receipt for \(item.title): shown on \(Self.stamp(proof.presentedAt)) from run \(prior.id).")
                } else if let refused = answer.refused.first(where: { $0.job == item.job && $0.periodKey == item.periodKey }) {
                    record.items[index].state = .refused
                    record.items[index].detail = refused.reason
                    state.sections.append("The posting receipt for \(item.title) was refused: \(refused.reason)")
                    state.failures.append(Self.needsReviewPrefix + "\(item.title) changed after it was shown.")
                }
            }
            if let data = try? JSONEncoder.sortedPretty().encode(record) {
                try? store.writeRunFile(automationID: automation.id, runID: prior.id, name: PublicationRecord.fileName, data: data)
            }
        }
    }

    func publicationRecord(automationID: String, runID: String) -> PublicationRecord? {
        guard let data = try? store.readRunFile(automationID: automationID, runID: runID, name: PublicationRecord.fileName) else { return nil }
        return try? JSONDecoder().decode(PublicationRecord.self, from: data)
    }

    /// An earlier run that already offers this exact report to the notch and may still show it. Nil when none.
    private func pendingPresentation(of wanted: PublicationItem, automationID: String, excluding runID: String) -> String? {
        for prior in store.runs(for: automationID, limit: 30) where prior.id != runID && prior.state == .succeeded && !prior.alerted {
            guard let finished = prior.finished, Date().timeIntervalSince(finished) <= AlertDecision.maxAge,
                  let record = publicationRecord(automationID: automationID, runID: prior.id),
                  record.items.contains(where: { $0.state == .pending && $0.sameReport(wanted) }),
                  (try? store.readRunFile(automationID: automationID, runID: prior.id, name: PresentationProof.fileName)) == nil
            else { continue }
            return prior.id
        }
        return nil
    }

    // MARK: Scripts

    struct StageScript {
        var stdout: Data
        var failureText: String
        var exitedZero = false
        /// Set when the run must stop now (cancel), or the stage could not run at all.
        var stop: Step?
        var stopText: String? { if case .done(_, let why)? = stop { return why }; return nil }
    }

    private func runStageScript(_ run: inout RunRecord, _ script: ScriptTask, extra: [String], automation: Automation,
                                timeout: TimeInterval, control: RunControl, label: String, item: String? = nil,
                                state: inout StagedState) -> StageScript {
        let started = Date()
        func stop(_ step: Step, _ why: String) -> StageScript {
            log(&run, &state, StageEntry(stage: label, item: item, state: "failed", started: started, finished: Date(), detail: why))
            return StageScript(stdout: Data(), failureText: why, stop: step)
        }
        guard timeout >= 10 else { return stop(.done(.failed, "The run reached its time limit before \(label)."), "No time left.") }
        if let approved = automation.approvedProgram, script.executable == approved.path,
           !approved.matches(ProgramIdentity.read(path: script.executable, hash: approved.sha256 != nil)) {
            return stop(.done(.failed, Self.programChanged), Self.programChanged)
        }
        if let changed = changedFile(automation) { return stop(.done(.failed, Self.fileChanged(changed)), Self.fileChanged(changed)) }
        var env = RunnerCommand.environment(base: context.baseEnvironment, path: context.settings.scriptPath)
        for (k, v) in script.environment where !RunnerCommand.isBlocked(k) { env[k] = v }
        for name in script.secretNames {
            guard let value = context.secret(name) else { return stop(.done(.failed, "The secret \(name) could not be read."), "Missing secret.") }
            env[name] = value
        }
        let launch = ProcessLaunch(executable: script.executable, arguments: script.arguments + extra, environment: env,
                                   workingDirectory: script.workingDirectory, stdin: Data())
        let supervisor = control.supervisor(killGrace: context.killGrace)
        supervisor.stdoutTailBytes = StagedHandoff.maxBytes
        let outcome = supervise(&run, supervisor, launch, timeout: timeout)
        let secrets = script.secretNames.compactMap { env[$0] } + Array(script.environment.values)
        let stderr = Redactor.redact(Redactor.tail(outcome.stderrTail, maxBytes: Self.stderrBytes), known: secrets)
        // The whole bounded, redacted stderr stays in the run folder for diagnosis.
        if !stderr.isEmpty {
            try? store.writeRunFile(automationID: run.automationID, runID: run.id, name: Self.stderrName(label, item), data: Data(stderr.utf8))
        }
        let tail = Self.lastLine(stderr).map { " " + $0 } ?? ""
        switch outcome.reason {
        case .cancelled: return stop(.done(.cancelled, "Cancelled."), "Cancelled.")
        case .timedOut: return stop(.done(.failed, "The \(label) stage stopped after \(Int(timeout)) seconds."), "Timed out.")
        case .spawnFailed(let why): return stop(.done(.failed, why), why)
        case .identityNotSaved: return stop(.done(.failed, Self.identityNotSaved), Self.identityNotSaved)
        case .signaled, .exited: break
        }
        // A planner or finish script may exit non-zero with a JSON result that says why; the caller reads it.
        let text = outcome.succeeded ? "" : "Exited with code \(outcome.exitCode.map(String.init) ?? "none")." + tail
        log(&run, &state, StageEntry(stage: label, item: item, state: outcome.succeeded ? "succeeded" : "failed", started: started,
                                     finished: Date(), detail: outcome.succeeded ? nil : String(text.prefix(500))))
        return StageScript(stdout: outcome.stdoutTail, failureText: text, exitedZero: outcome.succeeded, stop: nil)
    }

    // MARK: Output

    private func finishStaged(_ run: inout RunRecord, _ state: StagedState, stop: Step?, quietSummary: String = "") -> Step {
        var text = state.sections.joined(separator: "\n\n")
        if text.utf8.count > Self.stagedOutputBytes { text = String(decoding: Data(text.utf8.prefix(Self.stagedOutputBytes)), as: UTF8.self) }
        if text.isEmpty { text = quietSummary.isEmpty ? "No output." : quietSummary }
        // Without its durable output the run has nothing to show, so it cannot succeed.
        guard writeOutput(&run, text) else { return stop ?? .done(.failed, "The run's output could not be saved.") }
        if !state.publications.isEmpty {
            let record = PublicationRecord(automationID: run.automationID, runID: run.id, items: state.publications)
            do {
                try store.writeRunFile(automationID: run.automationID, runID: run.id, name: PublicationRecord.fileName,
                                       data: JSONEncoder.sortedPretty().encode(record))
            } catch {
                return stop ?? .done(.failed, "The report is saved but could not be offered for display (\(error)). The next run offers it again.")
            }
        }
        if let stop { return stop }
        if let first = state.failures.first {
            run.summary = String(first.prefix(200))
            return .done(.failed, first)
        }
        if !state.publications.isEmpty {
            run.summary = Self.reportReadyPrefix + state.publications.map(\.title).joined(separator: "; ")
            run.quiet = false
            return .done(.succeeded, nil)
        }
        run.summary = quietSummary.isEmpty ? (state.recorded > 0 ? "Posting receipts recorded" : "Nothing due") : String(quietSummary.prefix(200))
        run.quiet = true
        return .done(.succeeded, nil)
    }

    private func log(_ run: inout RunRecord, _ state: inout StagedState, _ entry: StageEntry) {
        state.stages.append(entry)
        if state.stages.count > 40 { state.stages.removeFirst(state.stages.count - 40) }
        if let data = try? JSONEncoder.sortedPretty().encode(state.stages) {
            try? store.writeRunFile(automationID: run.automationID, runID: run.id, name: Self.stagesFile, data: data)
        }
    }

    /// A stage's time: its own limit, cut to what is left of the run's limit.
    private func stageTime(_ limit: Int, _ deadline: Date) -> TimeInterval {
        min(TimeInterval(limit), deadline.timeIntervalSinceNow)
    }

    /// `preflight-stderr.txt`, `finish-<item>-stderr.txt`.
    static func stderrName(_ label: String, _ item: String?) -> String {
        let tag = item.map { "-" + $0.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.reduce("") { $0 + String($1) } } ?? ""
        return String((label + tag).prefix(100)) + "-stderr.txt"
    }

    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

extension JSONEncoder {
    static func sortedPretty() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
