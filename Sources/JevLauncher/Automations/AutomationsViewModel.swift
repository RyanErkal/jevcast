import AppKit
import Combine
import LauncherCore

/// What every Automations view reads. In normal use it passes through to `AutomationCenter` and
/// `QuillTaskCenter`; in demo mode it serves `AutomationsDemoData` and every action does nothing.
@MainActor
final class AutomationsViewModel: ObservableObject {
    enum Section: String, Hashable, CaseIterable, Identifiable {
        case needsYou, all, running, failed, history, quill, codex, clients
        var id: String { rawValue }
        var title: String {
            switch self {
            case .needsYou: return "Needs You"
            case .all: return "All Automations"
            case .running: return "Running"
            case .failed: return "Failed Recently"
            case .history: return "History"
            case .quill: return "Quill Tasks"
            case .codex: return "Codex"
            case .clients: return "Clients"
            }
        }
        var symbol: String {
            switch self {
            case .needsYou: return "hand.raised"
            case .all: return "square.stack.3d.up"
            case .running: return "play.circle"
            case .failed: return "exclamationmark.triangle"
            case .history: return "clock.arrow.circlepath"
            case .quill: return "text.quote"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .clients: return "chart.bar.xaxis"
            }
        }
        /// Sections that list runs rather than automations.
        var listsRuns: Bool { [.needsYou, .running, .failed, .history].contains(self) }
    }

    /// The editor sheet's input.
    struct EditorRequest: Identifiable {
        let id = UUID()
        var draft: AutomationDraft
    }

    let center: AutomationCenter?
    let quill: QuillTaskCenter?
    let demo: AutomationsDemoData?
    var isDemo: Bool { demo != nil }

    @Published var section: Section = .all
    @Published var selectedAutomationID: String?
    @Published var selectedRunID: String?
    @Published var search = ""
    @Published var editor: EditorRequest?
    /// A short message shown at the bottom, such as why an automation could not be turned on.
    @Published var banner: String?
    @Published var pendingDelete: Automation?
    @Published var showQuillExplainer = false

    /// Set by the app: opens Quill's new-task flow (the launcher).
    var onNewQuillTask: (() -> Void)?
    private var resultWindows: [QuillResultWindow] = []
    private var watchers: Set<AnyCancellable> = []

    init(center: AutomationCenter?, quill: QuillTaskCenter?, demo: AutomationsDemoData? = nil) {
        self.center = center; self.quill = quill; self.demo = demo
        // Views observe this object only; changes in either center redraw them.
        center?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &watchers)
        quill?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &watchers)
    }

    // MARK: Data

    var automations: [Automation] { demo?.automations ?? center?.automations ?? [] }
    var runnerStatus: AutomationCenter.RunnerStatus { demo?.runnerStatus ?? center?.runnerStatus ?? .off }
    var needsYou: [RunRecord] { demo?.needsYou ?? center?.needsYou ?? [] }
    var codex: [CodexAutomation] { demo?.codex ?? center?.codex ?? [] }
    var clients: [AutomationCenter.ClientEntry] { demo?.clients ?? center?.clients ?? [] }
    var problems: [String: String] { demo == nil ? center?.problems ?? [:] : [:] }
    var quillTasks: [QuillTask] { demo?.quillTasks ?? quill?.tasks ?? [] }

    func automation(_ id: String) -> Automation? { automations.first { $0.id == id } }
    func runs(for id: String) -> [RunRecord] { demo?.runs[id] ?? center?.runs[id] ?? [] }
    func lastRun(_ id: String) -> RunRecord? { runs(for: id).first }
    var allRuns: [RunRecord] {
        let source = demo?.runs ?? center?.runs ?? [:]
        return source.values.flatMap { $0 }.sorted { $0.queued > $1.queued }
    }
    func run(_ id: String) -> RunRecord? { allRuns.first { $0.id == id } }

    func nextRun(_ id: String) -> Date? {
        if let center, demo == nil { return center.nextRun(id) }
        guard let automation = automation(id) else { return nil }
        return Scheduler.nextRun(automation, lastCovered: nil, now: Date())
    }

    var filteredAutomations: [Automation] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = automations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(query) || $0.notes.lowercased().contains(query) || $0.kind.title.lowercased().contains(query) }
    }

    /// The runs a run-list section shows, filtered by the search text.
    func runs(in section: Section, now: Date = Date()) -> [RunRecord] {
        let list: [RunRecord]
        switch section {
        case .needsYou: list = needsYou
        case .running: list = allRuns.filter { $0.state.isActive }
        case .failed:
            let week = now.addingTimeInterval(-7 * 86400)
            list = allRuns.filter { [.failed, .interrupted, .expired].contains($0.state) && ($0.finished ?? $0.queued) > week }
        case .history: list = allRuns
        default: list = []
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return list }
        return list.filter { $0.automationName.lowercased().contains(query) || $0.summary.lowercased().contains(query) }
    }

    func count(_ section: Section) -> Int? {
        switch section {
        case .needsYou: return needsYou.isEmpty ? nil : needsYou.count
        case .running: let n = allRuns.filter { $0.state.isActive }.count; return n == 0 ? nil : n
        case .failed: let n = runs(in: .failed).count; return n == 0 ? nil : n
        default: return nil
        }
    }

    // MARK: Run content (call from .task, not from a view body: the center reads files)

    func output(of run: RunRecord) -> String? { demo.map { $0.outputs[run.id] } ?? center?.output(of: run) }
    func proposal(for run: RunRecord) -> Result<ProposalManifest, ProposalError>? {
        if let demo { return demo.proposals[run.id].map { .success($0) } }
        return center?.proposal(for: run)
    }
    func journal(for run: RunRecord) -> ApplyJournal? { demo == nil ? center?.journal(for: run) : nil }

    // MARK: Actions (no-ops in demo mode)

    var live: AutomationCenter? { demo == nil ? center : nil }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if let message = live?.setEnabled(id, enabled) { banner = message }
    }
    func runNow(_ id: String, test: Bool = false) {
        live?.runNow(id, test: test)
        if live != nil { banner = test ? "Test run queued." : "Run queued." }
    }
    func runSelected() { if let id = selectedAutomationID ?? selectedRun?.automationID { runNow(id) } }
    func cancel(_ run: RunRecord) { live?.cancel(run) }
    func answer(_ run: RunRecord, _ text: String) { live?.answer(run, text) }
    func revise(_ run: RunRecord, note: String) { live?.revise(run, note: note) }
    func approve(_ run: RunRecord, items: Set<String>) -> ApplyJournal? { live?.approve(run, items: items) }
    func reject(_ run: RunRecord) { live?.reject(run) }
    func undo(_ run: RunRecord) -> ApplyJournal? { live?.undo(run) }
    func reveal(_ run: RunRecord) { live?.revealRunFolder(run) }
    func delete(_ id: String) {
        live?.delete(id)
        if selectedAutomationID == id { selectedAutomationID = nil }
    }
    func duplicate(_ id: String) {
        guard let copy = live?.duplicate(id) else { return }
        section = .all; selectedAutomationID = copy.id
    }
    func turnOnRunner() { live?.turnOnRunner() }
    func openLoginItems() { live?.openLoginItems() }
    func importIssues(_ item: CodexAutomation) -> [String] { demo?.codexIssues[item.id] ?? center?.importIssues(item) ?? [] }
    func importedCopy(of item: CodexAutomation) -> Automation? { demo == nil ? center?.importedCopy(of: item) : nil }
    func importCodex(_ item: CodexAutomation) {
        guard let copy = live?.importCodex(item) else { return }
        section = .all; selectedAutomationID = copy.id
        banner = "Imported “\(copy.name)” as a paused copy."
    }
    func refreshClient(_ id: String) { live?.refreshClient(id) }
    func openDashboard(_ id: String) { live?.openDashboard(id) }

    /// Saves the editor's automation. A new one is saved paused, then turned on when asked.
    /// Returns an error to show in the sheet, or nil when it saved.
    func save(_ draft: AutomationDraft, isExecutable: (String) -> Bool) -> String? {
        guard let automation = draft.build(isExecutable: isExecutable) else { return "Fix the items listed first." }
        guard let center = live else { return nil }
        if let error = center.save(automation) { return error }
        if draft.isNew, draft.enableAfterSaving, let message = center.setEnabled(automation.id, true) { banner = message }
        section = .all; selectedAutomationID = automation.id
        return nil
    }

    // MARK: Editor and selection

    func newAutomation(_ template: AutomationTemplate = .blank) {
        if template.isQuillTask { showQuillExplainer = true; return }
        let bun = template == .metricsRefresh ? AutomationTemplate.detectBun() : nil
        editor = EditorRequest(draft: template.draft(bunPath: bun))
    }
    func edit(_ id: String) {
        guard let automation = automation(id) else { return }
        editor = EditorRequest(draft: AutomationDraft(automation))
    }
    func requestDeleteSelected() {
        guard section == .all, let id = selectedAutomationID, let automation = automation(id) else { return }
        pendingDelete = automation
    }
    var selectedRun: RunRecord? { selectedRunID.flatMap(run) }
    var selectedAutomation: Automation? { selectedAutomationID.flatMap(automation) }

    func open(automationID: String?, runID: String?) {
        if let runID, let run = run(runID) {
            section = run.state.needsUser ? .needsYou : .history
            selectedRunID = run.id
        } else if let automationID {
            section = .all; selectedAutomationID = automationID
        } else if !needsYou.isEmpty {
            section = .needsYou
        }
    }

    // MARK: Quill tasks

    func quillLastRun(_ id: String) -> QuillTaskRun? { demo?.quillRuns.first { $0.taskID == id } ?? quill?.lastRun(of: id) }
    func quillRunning(_ id: String) -> Bool { quill?.running.contains(id) ?? false }
    func setQuillEnabled(_ id: String, _ on: Bool) { if demo == nil { quill?.setEnabled(id, on) } }
    func runQuill(_ task: QuillTask) { if demo == nil { quill?.run(task) } }
    func openQuillResult(_ run: QuillTaskRun) {
        guard demo == nil else { return }
        let window = QuillResultWindow(run: run)
        resultWindows.removeAll { $0.window?.isVisible != true }
        resultWindows.append(window)
        window.show()
    }
    func newQuillTask() { showQuillExplainer = false; onNewQuillTask?() }
}
