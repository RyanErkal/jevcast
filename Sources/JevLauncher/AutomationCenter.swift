import AppKit
import LauncherCore

/// The app's view of automations: definitions, runs, the background runner, Codex, and client metrics.
/// The runner owns run state. This class reads the shared folder, writes definitions and requests,
/// checks and applies proposals, and shows notch alerts.
///
/// INTERFACE CONTRACT: views code against the members below. Bodies marked `TODO(center)` are
/// filled in by the integration step; keep every signature.
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

    @Published private(set) var automations: [Automation] = []
    /// Newest first, per automation, up to 50 each.
    @Published private(set) var runs: [String: [RunRecord]] = [:]
    /// Runs that wait for the user, newest first.
    @Published private(set) var needsYou: [RunRecord] = []
    /// Definition files that could not be read, by folder name.
    @Published private(set) var problems: [String: String] = [:]
    @Published private(set) var runnerStatus: RunnerStatus = .off
    @Published private(set) var settings = AutomationSettings()
    @Published private(set) var codex: [CodexAutomation] = []
    @Published private(set) var clients: [ClientEntry] = []
    @Published private(set) var codexTool: ToolInfo?
    @Published private(set) var claudeTool: ToolInfo?

    init(store: AutomationStore = AutomationStore()) {
        self.store = store
    }

    // MARK: Lifecycle

    /// Starts watching the folder and the runner signal. Cheap; safe to call more than once.
    func start() { /* TODO(center) */ }
    func stop() { /* TODO(center) */ }
    /// Re-reads everything now.
    func refresh() { /* TODO(center) */ }

    // MARK: Definitions

    func automation(_ id: String) -> Automation? { automations.first { $0.id == id } }
    func lastRun(_ id: String) -> RunRecord? { runs[id]?.first }
    func nextRun(_ id: String) -> Date? { nil /* TODO(center) */ }
    /// Saves a new or edited automation, bumping its revision and `updated`. Returns an error message on failure.
    @discardableResult func save(_ automation: Automation) -> String? { nil /* TODO(center) */ }
    /// Moves the automation's folder to the Trash.
    func delete(_ id: String) { /* TODO(center) */ }
    /// Returns a message when it cannot be turned on, for example while its Codex source is still active.
    @discardableResult func setEnabled(_ id: String, _ enabled: Bool) -> String? { nil /* TODO(center) */ }
    func duplicate(_ id: String) -> Automation? { nil /* TODO(center) */ }

    // MARK: Runs

    func runNow(_ id: String, test: Bool = false) { /* TODO(center) */ }
    func cancel(_ run: RunRecord) { /* TODO(center) */ }
    func answer(_ run: RunRecord, _ text: String) { /* TODO(center) */ }
    func revise(_ run: RunRecord, note: String) { /* TODO(center) */ }
    /// The report or script output.
    func output(of run: RunRecord) -> String? { nil /* TODO(center) */ }
    /// Checks the agent's raw proposal against the automation's roots and caches `proposal.json`.
    func proposal(for run: RunRecord) -> Result<ProposalManifest, ProposalError>? { nil /* TODO(center) */ }
    /// Applies the chosen items, records the journal, and marks the run succeeded.
    func approve(_ run: RunRecord, items: Set<String>) -> ApplyJournal? { nil /* TODO(center) */ }
    func reject(_ run: RunRecord) { /* TODO(center) */ }
    func journal(for run: RunRecord) -> ApplyJournal? { nil /* TODO(center) */ }
    func undo(_ run: RunRecord) -> ApplyJournal? { nil /* TODO(center) */ }
    func revealRunFolder(_ run: RunRecord) { /* TODO(center) */ }

    // MARK: Runner

    func turnOnRunner() { /* TODO(center) */ }
    func turnOffRunner() { /* TODO(center) */ }
    func openLoginItems() { /* TODO(center) */ }
    func saveSettings(_ settings: AutomationSettings) { /* TODO(center) */ }
    /// Looks for `codex` and `claude` in known places and records their paths in the settings.
    func detectTools() { /* TODO(center) */ }

    // MARK: Codex

    /// Issues that block turning on an import of this Codex automation.
    func importIssues(_ item: CodexAutomation) -> [String] { [] /* TODO(center) */ }
    /// The imported copy of a Codex automation, if any.
    func importedCopy(of item: CodexAutomation) -> Automation? { nil /* TODO(center) */ }
    /// Creates a paused copy and returns it.
    func importCodex(_ item: CodexAutomation) -> Automation? { nil /* TODO(center) */ }

    // MARK: Clients

    func saveClient(_ config: ClientConfig) { /* TODO(center) */ }
    func removeClient(_ id: String) { /* TODO(center) */ }
    func refreshClient(_ id: String) { /* TODO(center) */ }
    func openDashboard(_ id: String) { /* TODO(center) */ }

    // MARK: Windows (set by the app)

    /// Opens the Automations window, optionally on one automation or run.
    var openWindow: ((_ automationID: String?, _ runID: String?) -> Void)?
}
