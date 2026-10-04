import Foundation
import LauncherCore

/// The scheduler loop. All state lives on `queue`; runs execute on background threads.
final class Runner: @unchecked Sendable {
    static let tickInterval: TimeInterval = 30

    let store: AutomationStore
    let queue = DispatchQueue(label: "jevcast.runner")
    let pid = getpid()
    let started = Date()

    private struct Active { let automationID: String; let sharedLock: String?; let control: RunControl }
    private var active: [String: Active] = [:]
    /// Runs this process queued and has not started yet, oldest first: (automation ID, run ID).
    private var pending: [(String, String)] = []
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    /// The optional keep-awake-on-power assertion, separate from `activity`, which covers active runs.
    private let keepAwake = KeepAwake()
    private var shuttingDown = false
    private var ticks = 0
    /// Shared locks held by programs earlier runs left that could not be confirmed stopped. Recomputed each tick,
    /// so such a program blocks every automation that shares its lock (the same workspace), not only its own.
    private var leftoverLocks: Set<String> = []
    private let finished = DispatchGroup()

    init(store: AutomationStore) { self.store = store }

    func start() {
        queue.async {
            self.recoverInterruptedRuns()
            self.tick()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .seconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    /// Called for the Darwin signal and after wake.
    func poke() { queue.async { self.tick() } }

    // MARK: Tick

    private func tick() {
        guard !shuttingDown else { return }
        ticks += 1
        let settings = store.loadSettings()
        // Read once per tick; an edit made during the tick applies on the next one.
        let automations = store.loadAutomations().automations
        beat()
        expireWaitingRuns(automations)
        refreshLeftoverLocks(automations)
        handleRequests(settings)
        scheduleDue(settings, automations)
        startQueued(settings)
        updateKeepAwake(settings, automations)
        if ticks % 120 == 1 { store.prune(now: Date(), settings: settings) }
    }

    private func beat() {
        try? store.writeHeartbeat(RunnerHeartbeat(pid: pid, started: started, heartbeat: Date(),
                                                  version: RunnerIdentity.version, signedBuild: RunnerIdentity.signedBuild,
                                                  executable: RunnerIdentity.executablePath, build: RunnerIdentity.build))
    }

    /// A proposal older than seven days can no longer be approved. Its run becomes expired,
    /// so it stops blocking the next run. Journals and other run files stay.
    private func expireWaitingRuns(_ automations: [Automation]) {
        let now = Date()
        for automation in automations {
            for run in store.runs(for: automation.id, limit: 20) where active[run.id] == nil {
                guard let expired = WaitingRunExpiry.expired(run, now: now) else { continue }
                saveRun(expired)
            }
        }
    }

    private func handleRequests(_ settings: AutomationSettings) {
        for id in store.unreadableRequestIDs() { store.removeRequest(id: id) }
        for request in store.pendingRequests() {
            if handle(request, settings) { store.removeRequest(id: request.id) }
        }
    }

    /// Returns false to keep the request for a later tick.
    private func handle(_ request: RunnerRequest, _ settings: AutomationSettings) -> Bool {
        switch request.action {
        case .reload: return true
        case .runNow(let automationID, let test):
            guard let automation = store.automation(id: automationID) else { return true }
            guard store.run(automationID: automationID, runID: request.id) == nil else { return true }
            guard !isBusy(automationID) else { log("\(automationID) is already running; Run Now ignored."); return true }
            enqueue(automation, trigger: test ? .test : .manual, occurrence: nil, runID: request.id)
            return true
        case .cancel(let automationID, let runID):
            if let a = active[runID] { a.control.cancel(); return true }
            if var run = store.run(automationID: automationID, runID: runID), run.state.needsUser || run.state == .queued {
                run.state = .cancelled; run.finished = Date(); run.ownerPID = nil; run.ownerStart = nil
                saveRun(run)
            }
            return true
        case .answer(let automationID, let runID, let round, let text):
            return resume(automationID, runID, expect: .needsInput, followUp: .answer(round: round, text: String(text.prefix(20_000))), settings)
        case .revise(let automationID, let runID, let note):
            return resume(automationID, runID, expect: .needsApproval, followUp: .revise(note: String(note.prefix(20_000))), settings)
        }
    }

    private func resume(_ automationID: String, _ runID: String, expect: RunState, followUp: RunFollowUp, _ settings: AutomationSettings) -> Bool {
        guard let automation = store.automation(id: automationID), var run = store.run(automationID: automationID, runID: runID),
              run.state == expect else { return true }
        refreshLeftoverLocks()
        guard !active.values.contains(where: { $0.automationID == automationID }),
              active.count < max(1, settings.maxConcurrentRuns), !lockTaken(automation.policy.sharedLock) else { return false }
        if case .answer(let round, _) = followUp, !run.questions.contains(where: { $0.round == round && $0.answer == nil }) { return true }
        run.trigger = .resume
        launch(run, automation, settings, followUp: followUp)
        return true
    }

    private func scheduleDue(_ settings: AutomationSettings, _ automations: [Automation]) {
        let now = Date()
        let claim = OccurrenceClaim(store: store)
        for automation in automations where automation.enabled {
            let result = claim.claimDue(automation, now: now, busy: isBusy(automation.id)) { self.prepare(&$0, automation) }
            switch result {
            case .queued(let run):
                if run.state == .queued { pending.append((automation.id, run.id)) } else { alertIfNeeded(run, automation) }
                AutomationSignal.post()
            case .failed(let why): log("Could not queue a scheduled run of \(automation.id): \(why)")
            case .nothing, .skipped, .alreadyClaimed: break
            }
        }
    }

    /// Writes a queued run owned by this runner. The Codex guard is checked here and again at start.
    private func enqueue(_ automation: Automation, trigger: RunTrigger, occurrence: Date?, runID: String) {
        var run = RunRecord(id: runID, automation: automation, trigger: trigger, occurrence: occurrence)
        prepare(&run, automation)
        saveRun(run)
        if run.state == .queued { pending.append((automation.id, run.id)) } else { alertIfNeeded(run, automation) }
    }

    /// Sets this runner as owner, or fails the run at once when its Codex original still runs.
    private func prepare(_ run: inout RunRecord, _ automation: Automation) {
        run.ownerPID = pid; run.ownerStart = started
        if case .blocked(let why) = CodexSourceGuard.check(automation) {
            run.state = .failed; run.error = why; run.summary = "Blocked: Codex original is not paused"; run.finished = Date()
            run.ownerPID = nil; run.ownerStart = nil
        }
    }

    private func startQueued(_ settings: AutomationSettings) {
        guard !shuttingDown else { return }
        // A run that just ended may have left a program; its lock must hold before anything queued starts.
        refreshLeftoverLocks()
        var waiting: [(String, String)] = []
        for (automationID, runID) in pending {
            guard let run = store.run(automationID: automationID, runID: runID), run.state == .queued else { continue }
            guard let automation = store.automation(id: automationID) else { continue }
            let busy = active.values.contains { $0.automationID == automationID } || lockTaken(automation.policy.sharedLock)
            guard active.count < max(1, settings.maxConcurrentRuns), !busy else { waiting.append((automationID, runID)); continue }
            if case .blocked(let why) = CodexSourceGuard.check(automation) {
                var r = run; r.state = .failed; r.error = why; r.finished = Date(); r.ownerPID = nil; r.ownerStart = nil
                r.summary = "Blocked: Codex original is not paused"
                saveRun(r); alertIfNeeded(r, automation); continue
            }
            launch(run, automation, settings, followUp: nil)
        }
        pending = waiting
    }

    private func launch(_ run: RunRecord, _ automation: Automation, _ settings: AutomationSettings, followUp: RunFollowUp?) {
        let control = RunControl()
        active[run.id] = Active(automationID: automation.id, sharedLock: automation.policy.sharedLock, control: control)
        updateActivity(settings)
        var context = RunEngine.Context(settings: settings, ownerPID: pid, ownerStart: started, secret: { SecretStore.value($0) })
        context.toolExecutable = RunnerIdentity.executablePath
        let engine = RunEngine(store: store, context: context) { _ in AutomationSignal.post() }
        finished.enter()
        DispatchQueue.global(qos: .utility).async {
            let result = engine.execute(run, automation: automation, control: control, followUp: followUp)
            self.queue.async {
                self.ended(result, automation, settings)
                self.finished.leave()
            }
        }
    }

    private func ended(_ run: RunRecord, _ automation: Automation, _ settings: AutomationSettings) {
        active[run.id] = nil
        updateActivity(settings)
        if shuttingDown, run.state == .cancelled {
            var r = run; r.state = .interrupted; r.error = "The runner stopped during this run."
            saveRun(markRepeat(r))
            return
        }
        let run = markRepeat(run)
        alertIfNeeded(run, automation)
        AutomationSignal.post()
        startQueued(store.loadSettings())
    }

    private func alertIfNeeded(_ run: RunRecord, _ automation: Automation) {
        AutomationSignal.post()
        if AlertLauncher.shouldAlert(run, policy: automation.policy) { AlertLauncher.openAppIfNeeded() }
    }

    /// Marks a failure that repeats the previous finished run's failure, so it does not alert again.
    private func markRepeat(_ run: RunRecord) -> RunRecord {
        guard [.failed, .interrupted].contains(run.state) else { return run }
        let previous = store.runs(for: run.automationID, limit: 20).first { $0.id != run.id && $0.state.isFinished }
        guard FailureDedupe.isRepeat(run, previous: previous), run.repeatFailure != true else { return run }
        var r = run; r.repeatFailure = true
        saveRun(r)
        return r
    }

    // MARK: Helpers

    private func isBusy(_ automationID: String) -> Bool {
        if active.values.contains(where: { $0.automationID == automationID }) { return true }
        // A run that is queued or waits for the user blocks the next one, and so does a program an
        // earlier run left that could not be confirmed stopped.
        var busy = false
        for run in store.runs(for: automationID, limit: 20) {
            if run.state.isActive || run.state.needsUser { busy = true; continue }
            if let resolved = OrphanRecovery.resolvedOrphan(run) { saveRun(resolved); continue }
            if leftoverBlocks(run) { busy = true }
        }
        return busy
    }

    /// True when a finished run left a program that may still run, or a record that cannot be checked. The reason
    /// goes on that run's error once, so the user sees why the automation waits and what clears it.
    private func leftoverBlocks(_ run: RunRecord) -> Bool {
        guard !run.state.isActive, let reason = StagedRecovery.blockReason(store: store, run: run) else { return false }
        if run.error?.contains(reason) != true {
            var r = run; r.error = [run.error, "Blocked: " + reason].compactMap { $0 }.joined(separator: " ")
            saveRun(r)
            log("\(run.automationID) waits: \(reason)")
        }
        return true
    }

    private func lockTaken(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return active.values.contains { $0.sharedLock == name } || leftoverLocks.contains(name)
    }

    /// Reads the automations itself unless the caller already has them.
    private func refreshLeftoverLocks(_ known: [Automation]? = nil) {
        var locks = Set<String>()
        for automation in known ?? store.loadAutomations().automations {
            guard let lock = automation.policy.sharedLock, !lock.isEmpty, !locks.contains(lock) else { continue }
            let runs = store.runs(for: automation.id, limit: 20).filter { active[$0.id] == nil && !$0.state.isActive }
            if runs.contains(where: leftoverBlocks) { locks.insert(lock) }
        }
        if locks != leftoverLocks, !locks.isEmpty { log("Waiting for programs left by earlier runs; locks held: \(locks.sorted().joined(separator: ", "))") }
        leftoverLocks = locks
    }

    private func saveRun(_ run: RunRecord) {
        do { try store.saveRun(run) } catch { log("Could not save run \(run.id): \(error)") }
        AutomationSignal.post()
    }

    private func updateActivity(_ settings: AutomationSettings) {
        if !active.isEmpty, activity == nil, settings.preventIdleSleep {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                             reason: "Jevcast automation run")
        } else if active.isEmpty, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        }
    }

    /// Checked each tick, so a change to the setting, the power source, or the automations applies within 30 seconds.
    private func updateKeepAwake(_ settings: AutomationSettings, _ automations: [Automation]) {
        let wanted = KeepAwakePolicy.wanted(settings: settings, automations: automations,
                                            power: settings.keepAwakeOnPower ? KeepAwake.powerSource() : .unknown,
                                            shuttingDown: shuttingDown, now: Date())
        keepAwake.update(wanted: wanted)
    }

    /// At start, runs another runner left active can no longer be owned by anyone (this process holds the lock).
    /// A queued run that never started is kept and started again when it is recent. An interrupted report
    /// workflow gets one recovery run, which plans from the saved artifacts; missed hours are never queued.
    private func recoverInterruptedRuns() {
        let now = Date()
        for automation in store.loadAutomations().automations {
            // A crash can leave the short-lived Claude sign-in copy behind; it holds a token.
            for run in store.runs(for: automation.id, limit: 200) {
                let copy = store.runFolder(automationID: automation.id, runID: run.id).appendingPathComponent(ClaudeSignIn.fileName)
                try? FileManager.default.removeItem(at: copy)
            }
            var recover = false
            for run in store.runs(for: automation.id, limit: 200) where [.queued, .running, .retryWaiting].contains(run.state) {
                guard !OrphanRecovery.ownerIsAlive(run, currentPID: pid) else { continue }
                if run.state == .queued, run.started == nil {
                    var r = run
                    if now.timeIntervalSince(run.queued) <= Self.maxQueuedAge {
                        r.ownerPID = pid; r.ownerStart = started
                        saveRun(r)
                        pending.append((automation.id, r.id))
                    } else {
                        r.state = .interrupted; r.finished = now; r.ownerPID = nil; r.ownerStart = nil
                        r.error = "The runner stopped before this run started, and it is too old to start late."
                        saveRun(r)
                    }
                    continue
                }
                // Stops the run's child group only when its leader's start time proves it is the same process.
                var r = OrphanRecovery.interrupt(run)
                if let left = StagedRecovery.stopFetchChildren(store: store, run: r, grace: 10), r.orphanPGID == nil {
                    r.orphanPGID = left.pgid > 1 ? left.pgid : nil; r.orphanStart = left.start
                    r.error = (r.error ?? "") + " " + (StagedRecovery.blockReason(store: store, run: r)
                        ?? "Its fetch command could not be confirmed stopped; this automation waits until it ends.")
                }
                saveRun(r)
                if case .staged = automation.kind, automation.enabled, run.trigger != .recovery { recover = true }
            }
            if recover, !isBusy(automation.id) {
                enqueue(automation, trigger: .recovery, occurrence: nil, runID: RunID.make())
            }
        }
    }

    /// A queued run older than this is not started after a runner restart.
    static let maxQueuedAge: TimeInterval = 24 * 3600

    // MARK: Shutdown

    /// Stops children, marks this runner's runs interrupted, then calls `done`.
    func shutdown(_ done: @escaping @Sendable () -> Void) {
        queue.async {
            self.shuttingDown = true
            self.timer?.cancel()
            self.keepAwake.release()
            for a in self.active.values { a.control.cancel() }
            // Queued runs that never started stay queued without an owner; the next runner start takes them.
            for (automationID, runID) in self.pending {
                guard let run = self.store.run(automationID: automationID, runID: runID), run.state == .queued else { continue }
                var r = run; r.ownerPID = nil; r.ownerStart = nil
                self.saveRun(r)
            }
            DispatchQueue.global().async {
                _ = self.finished.wait(timeout: .now() + 20)
                done()
            }
        }
    }
}
