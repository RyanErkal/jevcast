import Foundation
import LauncherCore

/// Starting points in the New Automation menu. Each fills a draft; nothing is saved until the user saves.
enum AutomationTemplate: String, CaseIterable, Identifiable {
    case blank, desktopTidy, downloadsSort, metricsRefresh, weeklyClientReport, morningBrief
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blank Automation"
        case .desktopTidy: return "Desktop Tidy"
        case .downloadsSort: return "Downloads Sort"
        case .metricsRefresh: return "Meta Metrics Refresh"
        case .weeklyClientReport: return "Weekly Client Report"
        case .morningBrief: return "Morning Brief"
        }
    }

    var symbol: String {
        switch self {
        case .blank: return "square.dashed"
        case .desktopTidy: return "menubar.dock.rectangle"
        case .downloadsSort: return "arrow.down.circle"
        case .metricsRefresh: return "chart.line.uptrend.xyaxis"
        case .weeklyClientReport: return "doc.text.magnifyingglass"
        case .morningBrief: return "sun.horizon"
        }
    }

    /// Morning brief is a Quill task, not a background automation.
    var isQuillTask: Bool { self == .morningBrief }

    /// A filled draft. `bun` is looked up when the template is chosen, never while drawing.
    func draft(home: String = Paths.home, bunPath: String? = nil, now: Date = Date()) -> AutomationDraft {
        var d = AutomationDraft()
        d.schedule.anchor = now
        switch self {
        case .blank, .morningBrief:
            d.name = ""; d.symbol = "gearshape.2"
        case .desktopTidy, .downloadsSort:
            let folder = self == .desktopTidy ? "Desktop" : "Downloads"
            d.name = self == .desktopTidy ? "Desktop tidy" : "Downloads sort"
            d.symbol = self == .desktopTidy ? "menubar.dock.rectangle" : "arrow.down.circle"
            d.kind = .agent; d.runner = .codex; d.effort = .medium; d.output = .proposal; d.access = .readOnly
            d.agentFolder = "~/" + folder; d.allowedRoots = ["~/" + folder]
            d.prompt = Self.tidyPrompt(folder)
            d.schedule.preset = .weekly; d.schedule.weekdays = [1]; d.schedule.hour = 18; d.schedule.minute = 0
        case .metricsRefresh:
            d.name = "Meta metrics refresh"; d.symbol = "chart.line.uptrend.xyaxis"
            d.kind = .scriptWithDiagnosis
            d.program = bunPath ?? "/opt/homebrew/bin/bun"
            d.argumentsText = "scripts/utils/redesign-daily-metrics.ts\n--client\nstein-firm"
            d.scriptFolder = "~/Dev/docs"
            d.sharedLock = "docs-metrics"
            d.schedule.preset = .everyHours; d.schedule.intervalHours = 4
            d.notes = "Change the client after --client to the one this refresh is for."
        case .weeklyClientReport:
            d.name = "Weekly client report"; d.symbol = "doc.text.magnifyingglass"
            d.kind = .agent; d.runner = .codex; d.effort = .high; d.output = .report; d.access = .workspaceWriteNetwork
            d.agentFolder = "~/Dev/docs"
            d.prompt = "Write this week's client report. Use only the numbers in the client's metrics files, keep each metric's exact name, and mark anything not measured as N/A. Do not send anything."
            d.schedule.preset = .weekly; d.schedule.weekdays = [2]; d.schedule.hour = 8; d.schedule.minute = 0
        }
        return d
    }

    static func tidyPrompt(_ folder: String) -> String {
        """
        Look at the loose files directly in ~/\(folder). Propose moving each one into a dated or typed folder \
        (for example "Screenshots/2026-09", "PDFs", "Images"), creating the folders you need. Propose moving \
        screenshots older than 14 days to the Trash. Never touch existing folders or anything inside them. \
        Give a short reason for each change.
        """
    }

    /// The first `bun` found in the usual places.
    static func detectBun(home: String = Paths.home) -> String? {
        ["/opt/homebrew/bin/bun", "/usr/local/bin/bun", home + "/.bun/bin/bun"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Symbols offered in the editor's icon picker.
enum AutomationSymbols {
    static let all = [
        "gearshape.2", "sparkles", "wand.and.stars", "doc.text.magnifyingglass", "chart.line.uptrend.xyaxis", "chart.bar.xaxis",
        "menubar.dock.rectangle", "arrow.down.circle", "folder", "tray.full", "archivebox", "trash",
        "envelope", "calendar", "clock", "bell", "terminal", "hammer",
        "externaldrive", "icloud.and.arrow.up", "arrow.triangle.2.circlepath", "checklist", "person.2", "bolt"
    ]
}

/// Model suggestions per runner. Empty uses the CLI's default.
enum AutomationModels {
    static func suggestions(_ runner: AgentRunner) -> [String] {
        runner == .codex ? ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"] : ["opus", "sonnet", "fable", "haiku"]
    }
}
