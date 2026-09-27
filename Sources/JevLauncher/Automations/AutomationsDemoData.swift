import Foundation
import LauncherCore

/// Invented automations, runs, and dashboards for `--snapshot-ui --demo` and tests. No real files or apps.
@MainActor
struct AutomationsDemoData {
    var automations: [Automation] = []
    var runs: [String: [RunRecord]] = [:]
    var runnerStatus: AutomationCenter.RunnerStatus = .running(since: Date().addingTimeInterval(-7200))
    var codex: [CodexAutomation] = []
    var codexIssues: [String: [String]] = [:]
    var dashboards: [AutomationCenter.DashboardEntry] = []
    var quillTasks: [QuillTask] = []
    var quillRuns: [QuillTaskRun] = []
    var outputs: [String: String] = [:]
    var proposals: [String: ProposalManifest] = [:]

    var needsYou: [RunRecord] { runs.values.flatMap { $0 }.filter { $0.state.needsUser }.sorted { $0.queued > $1.queued } }

    static let approvalRunID = "20260926T180000Z-demo"
    static let failedRunID = "20260926T120000Z-fail"

    static func make(now: Date = Date()) -> AutomationsDemoData {
        var d = AutomationsDemoData()
        let home = "/Users/demo"
        let week = now.addingTimeInterval(-30 * 86400)

        var tidy = Automation(id: "desktop-tidy-demo", name: "Desktop tidy", symbol: "menubar.dock.rectangle",
                              kind: .agent(AgentTask(runner: .codex, prompt: AutomationTemplate.tidyPrompt("Desktop"), model: "gpt-6-sol", effort: .medium,
                                                     workingDirectory: home + "/Desktop", allowedRoots: [home + "/Desktop"], output: .proposal)),
                              schedule: Schedule(rule: .rrule("FREQ=WEEKLY;BYDAY=SU;BYHOUR=18;BYMINUTE=0"), anchor: week), enabled: true, created: week)
        tidy.notes = "Keeps the Desktop clear for screen sharing."
        let sales = Automation(id: "sales-data-demo", name: "Sales data refresh", symbol: "chart.line.uptrend.xyaxis",
                               kind: .scriptWithDiagnosis(ScriptTask(executable: "/bin/zsh",
                                                                     arguments: ["scripts/refresh-sales.sh", "--out", "data/sales.json"],
                                                                     workingDirectory: home + "/Projects/reports"),
                                                          AgentTask(prompt: AutomationDraft.defaultDiagnosisPrompt, workingDirectory: home + "/Projects/reports")),
                               schedule: Schedule(rule: .rrule("FREQ=HOURLY;INTERVAL=4"), anchor: week),
                               policy: Policy(retries: 1, sharedLock: "reports-data"), enabled: true, created: week,
                               source: .init(app: .codex, sourceID: "sales-data-refresh", path: home + "/.codex/automations/sales-data-refresh/automation.toml", hash: "demo"))
        let report = Automation(id: "weekly-report-demo", name: "Weekly report", symbol: "doc.text.magnifyingglass",
                                kind: .agent(AgentTask(runner: .claude, prompt: "Write this week's report from the data files.", model: "claude-opus-5-5", effort: .high,
                                                       workingDirectory: home + "/Projects/reports", access: .workspaceWriteNetwork, output: .report)),
                                schedule: Schedule(rule: .rrule("FREQ=WEEKLY;BYDAY=MO;BYHOUR=8;BYMINUTE=0"), anchor: week), enabled: true, created: week)
        let backup = Automation(id: "docs-backup-demo", name: "Documents backup", symbol: "externaldrive",
                                kind: .script(ScriptTask(executable: "/bin/zsh", arguments: ["scripts/backup.sh"], workingDirectory: home + "/Documents")),
                                schedule: Schedule(rule: .manual, anchor: week), enabled: false, created: week)
        d.automations = [tidy, sales, report, backup]

        func run(_ a: Automation, _ id: String, _ state: RunState, ago: TimeInterval, length: TimeInterval, summary: String,
                 trigger: RunTrigger = .schedule, tokens: TokenUsage? = nil, error: String? = nil) -> RunRecord {
            var r = RunRecord(id: id, automation: a, trigger: trigger, occurrence: now.addingTimeInterval(-ago), queued: now.addingTimeInterval(-ago))
            r.state = state; r.started = now.addingTimeInterval(-ago + 2)
            r.finished = state.isFinished || state.needsUser ? now.addingTimeInterval(-ago + 2 + length) : nil
            r.summary = summary; r.usage = tokens; r.error = error
            return r
        }
        let approval = run(tidy, approvalRunID, .needsApproval, ago: 1800, length: 94, summary: "4 changes to tidy the Desktop",
                           tokens: TokenUsage(input: 18_400, cachedInput: 9_000, output: 1_250))
        d.runs[tidy.id] = [approval,
                           run(tidy, "20260919T180000Z-a1", .succeeded, ago: 7 * 86400, length: 81, summary: "Moved 6 files", tokens: TokenUsage(input: 16_000, output: 900))]
        d.runs[sales.id] = [run(sales, failedRunID, .failed, ago: 3 * 3600, length: 41, summary: "The sales API returned an error",
                                error: "Sales API: request limit reached (429). Exit status 1."),
                            run(sales, "20260926T080000Z-s2", .succeeded, ago: 7 * 3600, length: 38, summary: "Refreshed 3 sources")]
        d.runs[report.id] = [run(report, "20260926T140000Z-r1", .running, ago: 240, length: 0, summary: "", trigger: .manual)]
        d.outputs[failedRunID] = "[sales] fetching orders…\n[sales] retry 1/1 after 30s\nError: request limit reached (429)\n    at fetchOrders (scripts/refresh-sales.sh:41)"
        d.outputs["20260926T080000Z-s2"] = "## Refresh complete\n\n- **Orders**: 3 days closed through 2026-09-25\n- **Leads**: 42 new\n\nNo problems found."

        let items: [(String, ProposalItem.Operation, String, String?, String)] = [
            ("1", .mkdir, home + "/Desktop/Screenshots/2026-09", nil, "Folder for this month's screenshots"),
            ("2", .move, home + "/Desktop/Screenshot 2026-09-24 at 10.12.44.png", home + "/Desktop/Screenshots/2026-09/Screenshot 2026-09-24 at 10.12.44.png", "Screenshot from this month"),
            ("3", .move, home + "/Desktop/Invoice-0932.pdf", home + "/Desktop/PDFs/Invoice-0932.pdf", "Loose PDF"),
            ("4", .trash, home + "/Desktop/Screenshot 2026-08-30 at 16.03.10.png", nil, "Screenshot older than 14 days")
        ]
        let identity = FileIdentity(device: 1, inode: 1, isDirectory: false, size: 1, modified: now, linkCount: 1)
        let proposalItems = items.map { i in
            ProposalItem(id: i.0, op: i.1, path: i.1 == .move ? nil : i.2, from: i.1 == .move ? i.2 : nil, to: i.3, reason: i.4)
        }
        let checked = items.prefix(3).map { i in
            CheckedItem(item: proposalItems.first { $0.id == i.0 }!, source: i.2, destination: i.1 == .mkdir ? i.2 : i.3, identity: identity, parentIdentity: identity)
        }
        d.proposals[approvalRunID] = ProposalManifest(
            proposal: Proposal(summary: "Sort 2 loose files into folders and trash 1 old screenshot.", items: proposalItems),
            checked: Array(checked), refused: ["4": "The file changed after the proposal was made."], roots: [home + "/Desktop"], digest: "demo")

        d.codex = [
            CodexAutomation(id: "sales-data-refresh", name: "Sales data refresh", kind: "cron", status: .paused,
                            rrule: "RRULE:FREQ=HOURLY;INTERVAL=4", prompt: "Run the data script.", path: home + "/.codex/automations/sales-data-refresh/automation.toml", hash: "a"),
            CodexAutomation(id: "weekly-summary", name: "Weekly summary", kind: "cron", status: .active,
                            rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0", prompt: "Write the summary.", path: home + "/.codex/automations/weekly-summary/automation.toml", hash: "b")
        ]
        d.codexIssues["weekly-summary"] = ["Still ACTIVE in Codex. Pause it there first.", "No working folder in the source. Choose one before turning it on."]

        d.dashboards = [
            dashboard("sales", "Sales", now: now, updated: -3600, automationID: sales.id,
                      json: ["totals": ["revenue": 18420.5, "orders": 214, "conversion": 3.4], "generated_at": ""],
                      metrics: [("Revenue", "totals.revenue", .currency), ("Orders", "totals.orders", .number), ("Conversion", "totals.conversion", .percent)]),
            dashboard("support", "Support", now: now, updated: -30 * 3600, automationID: nil,
                      json: ["queue": ["open": 12, "median_reply_seconds": 2460], "status": "Normal", "generated_at": ""],
                      metrics: [("Open tickets", "queue.open", .number), ("Median reply", "queue.median_reply_seconds", .duration), ("Status", "status", .text)])
        ]

        d.quillTasks = [QuillTask(id: "brief", name: "Morning brief", prompt: "Brief me on today's meetings and unread mail.",
                                  schedule: .daily(hour: 8, minute: 0, weekdays: [2, 3, 4, 5, 6]), contexts: [.calendar, .unreadMail], created: week)]
        d.quillRuns = [QuillTaskRun(taskID: "brief", taskName: "Morning brief", date: now.addingTimeInterval(-5 * 3600), succeeded: true,
                                    preview: "Three meetings today · Two unread messages", file: nil)]
        return d
    }

    private static func dashboard(_ id: String, _ name: String, now: Date, updated: TimeInterval, automationID: String?,
                                  json: [String: Any], metrics: [(String, String, DashboardFormat)]) -> AutomationCenter.DashboardEntry {
        var root = json
        root["generated_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(updated))
        let config = DashboardConfig(id: id, name: name, filePath: "/Users/demo/Projects/reports/data/\(id).json",
                                     metrics: metrics.map { DashboardMetric(id: id + "." + $0.1, label: $0.0, keyPath: $0.1, format: $0.2) },
                                     updatedAtKeyPath: "generated_at", automationID: automationID,
                                     openPath: "/Users/demo/Projects/reports/\(id).html")
        return .init(config: config, snapshot: DashboardReader.snapshot(root, config: config), readError: nil, readAt: now)
    }
}
