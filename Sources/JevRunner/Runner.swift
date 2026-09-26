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
    private var shuttingDown = false
    private var ticks = 0
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
        beat()
        handleRequests(settings)
        scheduleDue(settings)
        startQueued(settings)
        if ticks % 120 == 1 { store.prune(now: Date(), settings: settings) }
    }

    private func beat() {
        try? store.writeHeartbeat(RunnerHeartbeat(pid: pid, started: started, heartbeat: Date(),
                                                  version: RunnerIdentity.version, signedBuild: RunnerIdentity.signedBuild))
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
            guard !isBusy(automationID) else { log("\(automationID) is already running; Run Now ignored."); return true }
            enqueue(automation, trigger: test ? .test : .manual, occurrence: nil)
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
        guard active.count < max(1, settings.maxConcurrentRuns), !lockTaken(automation.policy.sharedLock) else { return false }
        if case .answer(let round, _) = followUp, !run.questions.contains(where: { $0.round == round && $0.answer == nil }) { return true }
        run.trigger = .resume
        launch(run, automation, settings, followUp: followUp)
        return true
    }

    private func scheduleDue(_ settings: AutomationSettings) {
        let now = Date()
        for automation in store.loadAutomations().automations where automation.enabled {
            var state = store.state(for: automation.id)
            let due = Scheduler.due(automation, lastCovered: state.lastCovered, now: now)
            guard let covered = due.coveredThrough else { continue }
            state.lastCovered = covered
            if let occurrence = due.runs.first, !isBusy(automation.id) {
                state.lastRunID = enqueue(automation, trigger: .schedule, occurrence: occurrence)
            }
            try? store.saveState(state, for: automation.id)
        }
    }

    /// Writes a queued run owned by this runner. The Codex guard is checked here and again at start.
    @discardableResult
    private func enqueue(_ automation: Automation, trigger: RunTrigger, occurrence: Date?) -> String {
        var run = RunRecord(id: RunID.make(), automation: automation, trigger: trigger, occurrence: occurrence)
        run.ownerPID = pid; run.ownerStart = started
        if case .blocked(let why) = CodexSourceGuard.check(automation) {
            run.state = .failed; run.error = why; run.summary = "Blocked: Codex original is not paused"; run.finished = Date()
            run.ownerPID = nil; run.ownerStart = nil
            saveRun(run)
            alertIfNeeded(run, automation)
            return run.id
        }
        saveRun(run)
        pending.append((automation.id, run.id))
        return run.id
    }

    private func startQueued(_ settings: AutomationSettings) {
        guard !shuttingDown else { return }
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
        let context = RunEngine.Context(settings: settings, ownerPID: pid, ownerStart: started, secret: { SecretStore.value($0) })
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
            saveRun(r)
            return
        }
        alertIfNeeded(run, automation)
        AutomationSignal.post()
        startQueued(store.loadSettings())
    }

    private func alertIfNeeded(_ run: RunRecord, _ automation: Automation) {
        AutomationSignal.post()
        if AlertLauncher.shouldAlert(run, policy: automation.policy) { AlertLauncher.openAppIfNeeded() }
    }

    // MARK: Helpers

    private func isBusy(_ automationID: String) -> Bool {
        if active.values.contains(where: { $0.automationID == automationID }) { return true }
        // A run that is queued or waits for the user blocks the next one.
        return store.runs(for: automationID, limit: 20).contains { $0.state.isActive || $0.state.needsUser }
    }

    private func lockTaken(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return active.values.contains { $0.sharedLock == name }
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

    /// At start, runs another runner left active can no longer be owned by anyone (this process holds the lock).
    private func recoverInterruptedRuns() {
        for automation in store.loadAutomations().automations {
            for var run in store.runs(for: automation.id, limit: 200) where [.queued, .running, .retryWaiting].contains(run.state) {
                run.state = .interrupted
                run.error = "The runner stopped during this run. It was not repeated."
                run.finished = Date(); run.ownerPID = nil; run.ownerStart = nil
                saveRun(run)
            }
        }
    }

    // MARK: Shutdown

    /// Stops children, marks this runner's runs interrupted, then calls `done`.
    func shutdown(_ done: @escaping @Sendable () -> Void) {
        queue.async {
            self.shuttingDown = true
            self.timer?.cancel()
            for a in self.active.values { a.control.cancel() }
            for (automationID, runID) in self.pending {
                guard let run = self.store.run(automationID: automationID, runID: runID), run.state == .queued else { continue }
                var r = run; r.state = .interrupted; r.error = "The runner stopped before this run started."
                r.finished = Date(); r.ownerPID = nil; r.ownerStart = nil
                self.saveRun(r)
            }
            DispatchQueue.global().async {
                _ = self.finished.wait(timeout: .now() + 20)
                done()
            }
        }
    }
}
