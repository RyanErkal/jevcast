import AppKit
import LauncherCore

/// The app's view of automations: definitions, runs, the background runner, Codex, and client metrics.
/// The runner owns run state. This class reads the shared folder, writes definitions and requests,
/// checks and applies proposals, and shows notch alerts.
///
/// INTERFACE CONTRACT: views code against the members below. Keep every signature.
/// Watching is in `AutomationCenter+Watch.swift`, the runner and tools in `+Runner`, proposals in `+Proposals`,
/// clients in `+Clients`, and alerts in `+Alerts`.
@MainActor
final class AutomationCenter: ObservableObject {
    enum RunnerStatus: Equatable {
        /// This build is signed ad hoc; macOS will not register the runner.
        case unsignedBuild
        case off
        /// Registered, but the user must allow it in System Settings › General › Login Items.
        case needsApproval
        case starting
        case running(since: Date)
        /// Registered, but no heartbeat for over 90 seconds.
        case notResponding
        case failed(String)
        var title: String {
            switch self {
            case .unsignedBuild: return "Needs a signed build"
            case .off: return "Off"
            case .needsApproval: return "Allow in Login Items"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .notResponding: return "Not responding"
            case .failed(let message): return "Failed: " + message
            }
        }
        var isRunning: Bool { if case .running = self { return true } else { return false } }
    }

    /// A configured client metrics sidecar. Stored in `Automations/clients.json`.
    struct ClientConfig: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var profile: ClientMetricsProfile
        var metricsPath: String
        var dashboardPath: String?
        /// The automation that refreshes this client's metrics, for "Refresh now".
        var automationID: String?
    }

    struct ClientEntry: Identifiable {
        var config: ClientConfig
        var snapshot: ClientMetricsSnapshot?
        /// Set when the last read failed; the previous snapshot stays shown as stale.
        var readError: String?
        var readAt: Date?
        var id: String { config.id }
    }

    /// Detected CLI, with its version when it could be read.
    struct ToolInfo: Equatable {
        var path: String
        var version: String?
    }

    let store: AutomationStore

    @Published var automations: [Automation] = []
    /// Newest first, per automation, up to 50 each.
    @Published var runs: [String: [RunRecord]] = [:]
    /// Runs that wait for the user, newest first.
    @Published var needsYou: [RunRecord] = [] { didSet { if attentionCount != needsYou.count { attentionCount = needsYou.count } } }
    /// Definition files that could not be read, by folder name.
    @Published var problems: [String: String] = [:]
    @Published var runnerStatus: RunnerStatus = .off
    @Published var settings = AutomationSettings()
    @Published var codex: [CodexAutomation] = []
    @Published var clients: [ClientEntry] = []
    @Published var codexTool: ToolInfo?
    @Published var claudeTool: ToolInfo?

    // MARK: Added members (not in the original contract)

    /// Runs waiting for the user, for the menu-bar dot.
    @Published private(set) var attentionCount = 0
    /// The last runner heartbeat read from `runner.json`.
    @Published var heartbeat: RunnerHeartbeat?
    /// A short message for the last action that could not be done, such as a failed registration.
    @Published var message: String?
    /// True while `detectTools` runs.
    @Published var detectingTools = false
    @Published var applyingProposal = false
    /// The Codex registry folder, read only.
    nonisolated static let codexFolder = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/automations", isDirectory: true)
    /// Snapshot and demo runs: a temporary store, no runner, tools, Codex, clients seeding, or alerts.
    let isolated: Bool
    /// App-level alert switches, set by the app from Preferences.
    var alertSettings: () -> AlertSettings = { AlertSettings() }
    /// Seconds an alert stays up, set by the app.
    var alertSeconds: () -> Double = { 6 }
    /// Windows that show automations tell the center, so it rescans more often while they are open.
    var windowOpen = false { didSet { if windowOpen != oldValue { scheduleRescan() } } }

    // Internal state for the extensions.
    var started = false
    var signalObserver: AutomationSignal.Observer?
    var rootWatch: DirectoryWatch?
    var clientWatches: [DirectoryWatch] = []
    var clientViewers = 0
    var clientReadGeneration = 0
    var clientRefreshGenerations: [String: Int] = [:]
    var reloadTask: Task<Void, Never>?
    var rescanTask: Task<Void, Never>?
    var quietTask: Task<Void, Never>?
    var rootFingerprint = ""
    var states: [String: AutomationState] = [:]
    var enabledSince: Date?
    var signedBuild: Bool?
    var proposals: [String: Result<ProposalManifest, ProposalError>] = [:]
    var outputs: [String: String] = [:]
    var shownAlerts: Set<String> = []

    init(store: AutomationStore = AutomationStore()) {
        self.store = store
        self.isolated = false
    }

    /// A center on a throwaway store for snapshots and demos. It never registers, detects, or alerts.
    init(isolatedStore store: AutomationStore) {
        self.store = store
        self.isolated = true
    }

    // MARK: Lifecycle

    /// Starts watching the folder and the runner signal. Cheap; safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        if !isolated {
            signalObserver = AutomationSignal.observe { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            watchRoot()
        }
        if !isolated { recoverInterruptedApprovals() }
        reload()
        if !isolated {
            loadCodex()
            loadClients(seed: true)
            // After launch settles; reads `--version` of the saved or found CLIs off the main thread.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.detectTools()
            }
        }
        scheduleRescan()
    }

    /// Approvals run in this process, so at launch none can still be applying. One left in that state
    /// means Jevcast quit part way; mark it failed so the journal and Undo stay available and nothing re-runs.
    private func recoverInterruptedApprovals() {
        let store = self.store
        Task.detached(priority: .utility) {
            for var run in store.allRecentRuns(limit: 500) where run.state == .applying {
                run.state = .failed
                run.error = "Jevcast quit while applying these changes. The journal shows what changed; you can undo it here."
                run.summary = "File changes need review"
                run.journalFile = ApplyJournal.fileName
                run.finished = run.finished ?? Date()
                try? store.saveRun(run)
            }
            AutomationSignal.post()
        }
    }

    func stop() {
        started = false
        signalObserver = nil
        rootWatch = nil
        clientWatches = []
        reloadTask?.cancel(); rescanTask?.cancel(); quietTask?.cancel()
    }

    /// Re-reads everything now.
    func refresh() {
        reload()
        if !isolated { loadCodex(); loadClients(seed: false) }
    }

    // MARK: Definitions

    func automation(_ id: String) -> Automation? { automations.first { $0.id == id } }
    func lastRun(_ id: String) -> RunRecord? { runs[id]?.first }
    func nextRun(_ id: String) -> Date? {
        guard let a = automation(id) else { return nil }
        return Scheduler.nextRun(a, lastCovered: states[id]?.lastCovered, now: Date())
    }

    /// Saves a new or edited automation, bumping its revision and `updated`. Returns an error message on failure.
    /// An automation saved as on that cannot run yet is saved paused, and the reason is returned.
    @discardableResult func save(_ automation: Automation) -> String? {
        guard AutomationID.isValid(automation.id) else { return "The automation ID is not valid." }
        var a = automation
        let name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Give the automation a name." }
        a.name = name
        if let existing = self.automation(a.id) { a.revision = max(existing.revision, a.revision) + 1 }
        a.updated = Date()
        var blocked: String?
        if a.enabled, let reason = enableProblem(a) { a.enabled = false; blocked = reason }
        do { try store.save(a) } catch { return "Could not save: \(error)" }
        if let index = automations.firstIndex(where: { $0.id == a.id }) { automations[index] = a } else {
            automations.append(a)
            automations.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        submit(.reload)
        return blocked
    }

    /// Moves the automation's folder to the Trash.
    func delete(_ id: String) {
        guard !applyingProposal, !store.runs(for: id, limit: 1000).contains(where: { $0.state.isActive }) else {
            message = "Cancel the active run and wait for it to stop before you delete this automation."
            return
        }
        do { try store.remove(id: id) } catch { message = "Could not move it to the Trash: \(error)"; return }
        automations.removeAll { $0.id == id }
        runs[id] = nil
        needsYou.removeAll { $0.automationID == id }
        submit(.reload)
    }

    /// Returns a message when it cannot be turned on, for example while its Codex source is still active.
    @discardableResult func setEnabled(_ id: String, _ enabled: Bool) -> String? {
        guard var a = automation(id) else { return "This automation no longer exists." }
        if enabled, let reason = enableProblem(a) { return reason }
        a.enabled = enabled
        return save(a)
    }

    func duplicate(_ id: String) -> Automation? {
        guard let original = automation(id) else { return nil }
        let name = original.name + " copy"
        var copy = Automation(id: AutomationID.make(from: name), name: name, symbol: original.symbol, kind: original.kind,
                              schedule: original.schedule, policy: original.policy, enabled: false, revision: 1,
                              created: Date(), source: original.source, notes: original.notes)
        copy.updated = copy.created
        if let problem = save(copy) { message = problem; return automation(copy.id) }
        return automation(copy.id)
    }

    /// Why this automation cannot be turned on now, or nil.
    func enableProblem(_ a: Automation) -> String? {
        if case .blocked(let reason) = CodexSourceGuard.check(a) { return reason }
        func folderMissing(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            let expanded = (path as NSString).expandingTildeInPath
            return path.isEmpty || !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) || !isDir.boolValue
        }
        func scriptProblem(_ s: ScriptTask) -> String? {
            if !FileManager.default.isExecutableFile(atPath: s.executable) { return "The program \(s.executable) is missing or cannot run." }
            if folderMissing(s.workingDirectory) { return "The working folder does not exist. Choose another in the editor." }
            return nil
        }
        func agentProblem(_ t: AgentTask) -> String? {
            let path = t.runner == .codex ? settings.codexPath : settings.claudePath
            if path.isEmpty || !FileManager.default.isExecutableFile(atPath: path) {
                return "\(t.runner.title) was not found. Detect it in Settings › Automations › Agents."
            }
            if folderMissing(t.workingDirectory) { return "The working folder does not exist. Choose another in the editor." }
            return nil
        }
        switch a.kind {
        case .script(let s): return scriptProblem(s)
        case .agent(let t): return agentProblem(t)
        case .scriptWithDiagnosis(let s, let t): return scriptProblem(s) ?? agentProblem(t)
        }
    }

    // MARK: Runs

    @discardableResult func runNow(_ id: String, test: Bool = false) -> Bool {
        guard submit(.runNow(automationID: id, test: test)) else { return false }
        if !runnerStatus.isRunning, !isolated {
            message = "Queued. It starts when the background runner is on (Settings › Automations)."
        }
        return true
    }
    func cancel(_ run: RunRecord) { submit(.cancel(automationID: run.automationID, runID: run.id)) }
    @discardableResult func answer(_ run: RunRecord, _ text: String) -> Bool {
        let round = run.questions.last(where: { $0.answer == nil })?.round ?? run.questions.last?.round ?? 1
        guard submit(.answer(automationID: run.automationID, runID: run.id, round: round, text: text)) else { return false }
        NotchAlertController.shared.withdraw(id: Self.alertID(run))
        return true
    }
    @discardableResult func revise(_ run: RunRecord, note: String) -> Bool {
        guard submit(.revise(automationID: run.automationID, runID: run.id, note: note)) else { return false }
        proposals[run.id] = nil
        NotchAlertController.shared.withdraw(id: Self.alertID(run))
        return true
    }
    /// The report or script output.
    func output(of run: RunRecord) -> String? {
        let key = run.id + "#\(run.state.rawValue)#\(run.outputFile ?? "")"
        if let cached = outputs[key] { return cached }
        guard let text = store.readOutput(run) else { return nil }
        if outputs.count > 20 { outputs.removeAll() }
        outputs[key] = text
        return text
    }
    func revealRunFolder(_ run: RunRecord) {
        let folder = store.runFolder(automationID: run.automationID, runID: run.id)
        guard FileManager.default.fileExists(atPath: folder.path) else { message = "The run folder was deleted."; return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Writes a request for the runner and wakes it. A failure shows in `message`.
    @discardableResult func submit(_ action: RunnerRequest.Action) -> Bool {
        guard !isolated else { return false }
        do { try store.submit(RunnerRequest(action: action)) } catch { message = "Could not reach the runner's folder: \(error)"; return false }
        AutomationSignal.post()
        scheduleReload()
        return true
    }

    // MARK: Runner

    func turnOnRunner() { registerRunner() }
    func turnOffRunner() { unregisterRunner() }
    func openLoginItems() { RunnerService.openLoginItems() }
    func saveSettings(_ settings: AutomationSettings) {
        var s = settings
        s.maxConcurrentRuns = min(max(s.maxConcurrentRuns, 1), 4)
        s.historyDays = max(s.historyDays, 1)
        if !isolated {
            do { try store.saveSettings(s) } catch { message = "Could not save settings: \(error)"; return }
            AutomationSignal.post()
        }
        self.settings = s
    }

    // MARK: Codex

    /// Issues that block turning on an import of this Codex automation.
    func importIssues(_ item: CodexAutomation) -> [String] {
        var issues = CodexImport.importIssues(for: item)
        if settings.codexPath.isEmpty { issues.append("Codex CLI not found. Detect it in Settings › Automations › Agents.") }
        return issues
    }
    /// The imported copy of a Codex automation, if any.
    func importedCopy(of item: CodexAutomation) -> Automation? {
        automations.first { $0.source?.app == .codex && $0.source?.sourceID == item.id }
    }
    /// Creates a paused copy and returns it.
    func importCodex(_ item: CodexAutomation) -> Automation? {
        if let existing = importedCopy(of: item) { return existing }
        let zone = TimeZone.current
        var a = CodexImport.makeAutomation(from: item, timeZone: zone.identifier, anchor: Self.importAnchor(item.rrule, zone: zone))
        a.enabled = false
        a.symbol = "arrow.down.doc"
        if let problem = save(a) { message = problem; return nil }
        return automation(a.id)
    }

    /// The next occurrence of the rule from local midnight, so an hourly phase starts on a clean boundary. Now when unknown.
    nonisolated static func importAnchor(_ rrule: String, zone: TimeZone, now: Date = Date()) -> Date {
        var text = rrule
        if text.uppercased().hasPrefix("RRULE:") { text = String(text.dropFirst(6)) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let rule = try? RRule(text),
              let next = rule.occurrences(after: now, anchor: calendar.startOfDay(for: now), timeZone: zone, limit: 1).first else { return now }
        return next
    }

    // MARK: Windows (set by the app)

    /// Opens Settings › Automations. Set by the app.
    var openSettings: (() -> Void)?
    /// Opens the Automations window, optionally on one automation or run.
    var openWindow: ((_ automationID: String?, _ runID: String?) -> Void)?
}
