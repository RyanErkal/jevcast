import Foundation
import LauncherCore

/// Invented automations, runs, and clients for `--snapshot-ui --demo` and tests. No real files or apps.
@MainActor
struct AutomationsDemoData {
    var automations: [Automation] = []
    var runs: [String: [RunRecord]] = [:]
    var runnerStatus: AutomationCenter.RunnerStatus = .running(since: Date().addingTimeInterval(-7200))
    var codex: [CodexAutomation] = []
    var codexIssues: [String: [String]] = [:]
    var clients: [AutomationCenter.ClientEntry] = []
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
        let stein = Automation(id: "stein-metrics-demo", name: "Stein metrics", symbol: "chart.line.uptrend.xyaxis",
                               kind: .scriptWithDiagnosis(ScriptTask(executable: "/opt/homebrew/bin/bun",
                                                                     arguments: ["scripts/utils/redesign-daily-metrics.ts", "--client", "stein-firm"],
                                                                     workingDirectory: home + "/Dev/docs"),
                                                          AgentTask(prompt: AutomationDraft.defaultDiagnosisPrompt, workingDirectory: home + "/Dev/docs")),
                               schedule: Schedule(rule: .rrule("FREQ=HOURLY;INTERVAL=4"), anchor: week),
                               policy: Policy(retries: 1, sharedLock: "docs-metrics"), enabled: true, created: week,
                               source: .init(app: .codex, sourceID: "stein-firm-daily-metrics", path: home + "/.codex/automations/stein-firm-daily-metrics/automation.toml", hash: "demo"))
        let report = Automation(id: "weekly-client-report-demo", name: "Weekly client report", symbol: "doc.text.magnifyingglass",
                                kind: .agent(AgentTask(runner: .claude, prompt: "Write this week's client report from the metrics files.", model: "opus", effort: .high,
                                                       workingDirectory: home + "/Dev/docs", access: .workspaceWriteNetwork, output: .report)),
                                schedule: Schedule(rule: .rrule("FREQ=WEEKLY;BYDAY=MO;BYHOUR=8;BYMINUTE=0"), anchor: week), enabled: true, created: week)
        let backup = Automation(id: "docs-backup-demo", name: "Docs backup", symbol: "externaldrive",
                                kind: .script(ScriptTask(executable: "/bin/zsh", arguments: ["scripts/backup.sh"], workingDirectory: home + "/Dev/docs")),
                                schedule: Schedule(rule: .manual, anchor: week), enabled: false, created: week)
        d.automations = [tidy, stein, report, backup]

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
        d.runs[stein.id] = [run(stein, failedRunID, .failed, ago: 3 * 3600, length: 41, summary: "Meta API returned an error",
                                error: "Meta Graph API: (#17) User request limit reached. Exit status 1."),
                            run(stein, "20260926T080000Z-s2", .succeeded, ago: 7 * 3600, length: 38, summary: "Refreshed 3 sources")]
        d.runs[report.id] = [run(report, "20260926T140000Z-r1", .running, ago: 240, length: 0, summary: "", trigger: .manual)]
        d.outputs[failedRunID] = "[metrics] fetching insights for act_1234…\n[metrics] retry 1/1 after 30s\nError: (#17) User request limit reached\n    at fetchInsights (scripts/utils/meta.ts:88)"
        d.outputs["20260926T080000Z-s2"] = "## Refresh complete\n\n- **Meta**: 3 days closed through 2026-09-25\n- **CRM**: 42 forms\n\nNo problems found."

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
            CodexAutomation(id: "stein-firm-daily-metrics", name: "Stein Firm daily metrics", kind: "cron", status: .paused,
                            rrule: "RRULE:FREQ=HOURLY;INTERVAL=4", prompt: "Run the metrics script.", path: home + "/.codex/automations/stein-firm-daily-metrics/automation.toml", hash: "a"),
            CodexAutomation(id: "goodrich-weekly-meta-ads-report", name: "Goodrich weekly report", kind: "cron", status: .active,
                            rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0", prompt: "Write the report.", path: home + "/.codex/automations/goodrich-weekly-meta-ads-report/automation.toml", hash: "b")
        ]
        d.codexIssues["goodrich-weekly-meta-ads-report"] = ["Still ACTIVE in Codex. Pause it there first.", "No working folder in the source. Choose one before turning it on."]

        d.clients = [client("stein", "Stein Firm", .stein, now: now, fresh: true,
                            kpis: ["spend": 4210.5, "formQualified": 37, "costPerFormQualified": 113.8, "metaFormQualified": 44]),
                     client("redesign", "ReDesign", .redesign, now: now, fresh: false,
                            kpis: ["spend": 2890, "paidTaggedForms": 19, "costPerForm": 152.1, "qualifiedMeetings": NSNull()])]

        d.quillTasks = [QuillTask(id: "brief", name: "Morning brief", prompt: "Brief me on today's meetings and unread mail.",
                                  schedule: .daily(hour: 8, minute: 0, weekdays: [2, 3, 4, 5, 6]), contexts: [.calendar, .unreadMail], created: week)]
        d.quillRuns = [QuillTaskRun(taskID: "brief", taskName: "Morning brief", date: now.addingTimeInterval(-5 * 3600), succeeded: true,
                                    preview: "Three meetings today · Two unread from clients", file: nil)]
        return d
    }

    private static func client(_ id: String, _ name: String, _ profile: ClientMetricsProfile, now: Date, fresh: Bool, kpis: [String: Any]) -> AutomationCenter.ClientEntry {
        let iso = ISO8601DateFormatter()
        let json: [String: Any] = [
            "schemaVersion": 4, "generatedAt": iso.string(from: now.addingTimeInterval(-3600)), "reportingTimezone": "America/Los_Angeles",
            "reportRange": ["from": "2026-09-01", "to": "2026-09-25"],
            "sourceFreshness": [
                ["source": "meta", "last_success_at": iso.string(from: now.addingTimeInterval(fresh ? -3600 : -14 * 3600)), "last_status": "success", "closed_day_through": "2026-09-25"],
                ["source": "crm", "last_success_at": iso.string(from: now.addingTimeInterval(fresh ? -2 * 3600 : -40 * 3600)), "last_status": fresh ? "success" : "error", "last_error": fresh ? "" : "Token expired"]
            ],
            "derivedKpis": kpis
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let snapshot = try? ClientMetricsReader.decode(data, profile: profile)
        let config = AutomationCenter.ClientConfig(id: id, name: name, profile: profile, metricsPath: "/Users/demo/metrics/\(id).json",
                                                   dashboardPath: "/Users/demo/metrics/\(id).html", automationID: nil)
        return .init(config: config, snapshot: snapshot, readError: nil, readAt: now)
    }
}
