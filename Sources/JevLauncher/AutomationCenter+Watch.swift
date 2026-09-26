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

    static func read(_ store: AutomationStore) -> AutomationReadout {
        let loaded = store.loadAutomations()
        var runs: [String: [RunRecord]] = [:], states: [String: AutomationState] = [:]
        for a in loaded.automations {
            runs[a.id] = store.runs(for: a.id, limit: 50)
            states[a.id] = store.state(for: a.id)
        }
        return AutomationReadout(automations: loaded.automations, problems: loaded.problems, runs: runs, states: states,
                                 settings: store.loadSettings(), heartbeat: store.readHeartbeat())
    }

    /// Names in the root and the modification times of the files that matter, without `runner.json`,
    /// which changes every 30 seconds.
    static func fingerprint(_ store: AutomationStore) -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).sorted()
        let times = ["settings.json", "clients.json"].map { name -> String in
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
        if runs != r.runs { runs = r.runs }
        states = r.states
        if !isolated, settings != r.settings { settings = r.settings }
        if heartbeat != r.heartbeat { heartbeat = r.heartbeat }
        let waiting = r.runs.values.flatMap { $0 }.filter { $0.state.needsUser }.sorted { ($0.queued, $0.id) > ($1.queued, $1.id) }
        if needsYou != waiting { needsYou = waiting }
        // A resolved run no longer needs its alert.
        let open = Set(waiting.map(Self.alertID))
        for id in shownAlerts where !open.contains(id) { NotchAlertController.shared.withdraw(id: id) }
        shownAlerts.formIntersection(open.union(r.runs.values.flatMap { $0 }.filter { $0.state == .failed || $0.state == .succeeded }.map(Self.alertID)))
        // Cached checks stay only for runs still waiting; others are read again from proposal.json when asked.
        proposals = proposals.filter { id, _ in waiting.contains { $0.id == id } }
        updateRunnerStatus()
        processAlerts()
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
