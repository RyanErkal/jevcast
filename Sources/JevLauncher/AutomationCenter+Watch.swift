import Foundation
import LauncherCore

/// Watches one folder for entries added, removed, or replaced. Stops when released.
final class DirectoryWatch {
    private let source: DispatchSourceFileSystemObject

    init?(_ url: URL, queue: DispatchQueue = .main, changed: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        source.setEventHandler(handler: changed)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// Everything a reload reads, gathered off the main thread.
struct AutomationReadout: Sendable {
    var automations: [Automation]
    var problems: [String: String]
    var runs: [String: [RunRecord]]
    var states: [String: AutomationState]
    var settings: AutomationSettings
    var heartbeat: RunnerHeartbeat?
    /// The last finished stage of each running report workflow, by `key(_:)`.
    var progress: [String: StageProgress] = [:]

    static func key(_ run: RunRecord) -> String { run.automationID + "/" + run.id }

    static func read(_ store: AutomationStore) -> AutomationReadout {
        let loaded = store.loadAutomations()
        var runs: [String: [RunRecord]] = [:], states: [String: AutomationState] = [:]
        var progress: [String: StageProgress] = [:]
        for a in loaded.automations {
            runs[a.id] = store.runs(for: a.id, limit: 50).map { record in
                var run = record
                if !run.alerted { run.alerted = AutomationAlertReceipt.wasDelivered(run, store: store) }
                return run
            }
            states[a.id] = store.state(for: a.id)
            guard case .staged = a.kind else { continue }
            for run in runs[a.id] ?? [] where run.state == .running {
                if let data = try? store.readRunFile(automationID: a.id, runID: run.id, name: RunEngine.stagesFile, maxBytes: 256 * 1024),
                   let stage = StageProgress.parse(data) {
                    progress[key(run)] = stage
                }
            }
        }
        return AutomationReadout(automations: loaded.automations, problems: loaded.problems, runs: runs, states: states,
                                 settings: store.loadSettings(), heartbeat: store.readHeartbeat(), progress: progress)
    }

    /// Names in the root and the modification times of the files that matter, without `runner.json`,
    /// which changes every 30 seconds.
    static func fingerprint(_ store: AutomationStore) -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).sorted()
        let times = ["settings.json"].map { name -> String in
            let date = (try? FileManager.default.attributesOfItem(atPath: store.root.appendingPathComponent(name).path))?[.modificationDate] as? Date
            return "\(date?.timeIntervalSinceReferenceDate ?? 0)"
        }
        return names.filter { $0 != "runner.json" && !$0.hasPrefix(".") }.joined(separator: "/") + "|" + times.joined(separator: "/")
    }
}

extension AutomationCenter {
    /// Coalesces bursts of signals and folder events into one read, 250 ms after the last.
    func scheduleReload() {
        guard started else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.reloadNow()
        }
    }

    /// Reads now, off the main thread, then publishes.
    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in await self?.reloadNow() }
    }

    func reloadNow() async {
        let store = self.store
        let readout = await Task.detached(priority: .utility) { AutomationReadout.read(store) }.value
        guard !Task.isCancelled else { return }
        apply(readout)
    }

    private func apply(_ r: AutomationReadout) {
        if automations != r.automations { automations = r.automations }
        if problems != r.problems { problems = r.problems }
        for id in shownAlerts {
            let previous = runs.values.flatMap { $0 }.first { Self.alertID($0) == id }
            let next = r.runs.values.flatMap { $0 }.first { Self.alertID($0) == id }
            if previous.map(AutomationAlertReceipt.init) != next.map(AutomationAlertReceipt.init) {
                NotchAlertController.shared.withdraw(id: id)
                shownAlerts.remove(id)
            }
        }
        if runs != r.runs { runs = r.runs }
        states = r.states
        stageProgress = r.progress
        if !isolated, settings != r.settings { settings = r.settings }
        if heartbeat != r.heartbeat { heartbeat = r.heartbeat }
        let waiting = r.runs.values.flatMap { $0 }.filter { $0.state.needsUser }.sorted { ($0.queued, $0.id) > ($1.queued, $1.id) }
        if needsYou != waiting { needsYou = waiting }
        let keep = Self.alertsToKeep(r.runs.values.flatMap { $0 })
        for id in shownAlerts where !keep.contains(id) { NotchAlertController.shared.withdraw(id: id) }
        shownAlerts.formIntersection(keep)
        // Cached checks stay only for runs still waiting; others are read again from proposal.json when asked.
        proposals = proposals.filter { id, _ in waiting.contains { $0.id == id } }
        updateRunnerStatus()
        processAlerts()
    }

    /// Alerts that still apply after a reload. A question or approval applies while the run waits for the user.
    /// A finished run's alert (success, failure, interruption) applies while the run is in that same state,
    /// whether or not it was drawn yet: the notch keeps it for its normal time or until the user dismisses it,
    /// and a locked screen or a busy queue must not lose it. A changed state is withdrawn earlier in `apply`.
    nonisolated static func alertsToKeep(_ runs: [RunRecord]) -> Set<String> {
        Set(runs.filter { $0.state.needsUser || [.failed, .interrupted, .succeeded].contains($0.state) }.map(alertID))
    }

    /// The root folder: a new, removed, or replaced entry means a reload. Only `runner.json` changing re-reads the heartbeat.
    func watchRoot() {
        try? store.ensureRoot()
        rootWatch = DirectoryWatch(store.root) { [weak self] in
            MainActor.assumeIsolated { self?.rootChanged() }
        }
    }

    private func rootChanged() {
        let store = self.store
        Task { @MainActor [weak self] in
            let print = await Task.detached(priority: .utility) { AutomationReadout.fingerprint(store) }.value
            guard let self else { return }
            if print != self.rootFingerprint {
                self.rootFingerprint = print
                self.scheduleReload()
            } else {
                let beat = await Task.detached(priority: .utility) { store.readHeartbeat() }.value
                if self.heartbeat != beat { self.heartbeat = beat }
                self.updateRunnerStatus()
            }
        }
    }

    /// A safety rescan: every 60 seconds while a window is open or a run is active, otherwise every 5 minutes.
    func scheduleRescan() {
        guard started else { return }
        rescanTask?.cancel()
        let busy = windowOpen || runs.values.contains { $0.contains { $0.state.isActive } } || runnerStatus == .starting
        let seconds: UInt64 = busy ? 60 : 300
        rescanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reloadNow()
            self.scheduleRescan()
        }
    }
}
