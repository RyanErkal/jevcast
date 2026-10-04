import AppKit
import LauncherCore

/// Starting points in the New Automation menu. Each fills a draft; nothing is saved until the user saves.
enum AutomationTemplate: String, CaseIterable, Identifiable {
    case blank, desktopTidy, downloadsSort, dataRefresh, weeklyReport, morningBrief
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blank Automation"
        case .desktopTidy: return "Desktop Tidy"
        case .downloadsSort: return "Downloads Sort"
        case .dataRefresh: return "Refresh a Data File"
        case .weeklyReport: return "Weekly Report"
        case .morningBrief: return "Morning Brief"
        }
    }

    var symbol: String {
        switch self {
        case .blank: return "square.dashed"
        case .desktopTidy: return "menubar.dock.rectangle"
        case .downloadsSort: return "arrow.down.circle"
        case .dataRefresh: return "arrow.triangle.2.circlepath"
        case .weeklyReport: return "doc.text.magnifyingglass"
        case .morningBrief: return "sun.horizon"
        }
    }

    /// Morning brief is a scheduled brief, not a background automation.
    var isScheduledBrief: Bool { self == .morningBrief }

    /// A filled draft. Templates hold no personal paths; folders use `~` or are left for the user.
    func draft(now: Date = Date()) -> AutomationDraft {
        var d = AutomationDraft()
        d.schedule.anchor = now
        switch self {
        case .blank, .morningBrief:
            d.name = ""; d.symbol = "gearshape.2"; d.accent = .blue
        case .desktopTidy, .downloadsSort:
            let folder = self == .desktopTidy ? "Desktop" : "Downloads"
            d.name = self == .desktopTidy ? "Desktop tidy" : "Downloads sort"
            d.symbol = self == .desktopTidy ? "menubar.dock.rectangle" : "arrow.down.circle"
            d.accent = self == .desktopTidy ? .teal : .cyan
            d.kind = .agent; d.runner = .codex; d.effort = .medium; d.output = .proposal; d.access = .readOnly
            d.agentFolder = "~/" + folder; d.allowedRoots = ["~/" + folder]
            d.prompt = Self.tidyPrompt(folder)
            d.schedule.preset = .weekly; d.schedule.weekdays = [1]; d.schedule.hour = 18; d.schedule.minute = 0
        case .dataRefresh:
            // Placeholders only: the user picks their own script, arguments, and folder.
            d.name = "Refresh a data file"; d.symbol = "arrow.triangle.2.circlepath"; d.accent = .indigo
            d.kind = .scriptWithDiagnosis
            d.program = "/bin/zsh"
            d.argumentsText = "path/to/refresh-script.sh\n--out\npath/to/data.json"
            d.scriptFolder = ""
            d.schedule.preset = .everyHours; d.schedule.intervalHours = 4
            d.notes = "Replace the script path and output file with your own."
        case .weeklyReport:
            d.name = "Weekly report"; d.symbol = "doc.text.magnifyingglass"; d.accent = .purple
            d.kind = .agent; d.runner = .codex; d.effort = .high; d.output = .report; d.access = .readOnly
            d.agentFolder = ""
            d.prompt = "Write a short report on this week's numbers from the data files in this folder. Keep each metric's exact name, and mark anything not measured as N/A. Do not send anything."
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
}

/// Symbols offered in the editor's icon picker. Any other SF Symbol may be typed in; `valid` checks it.
enum AutomationSymbols {
    static let all = [
        "gearshape.2", "sparkles", "wand.and.stars", "doc.text.magnifyingglass", "chart.line.uptrend.xyaxis", "chart.bar.xaxis",
        "menubar.dock.rectangle", "arrow.down.circle", "folder", "tray.full", "archivebox", "trash",
        "envelope", "calendar", "clock", "bell", "terminal", "hammer",
        "externaldrive", "icloud.and.arrow.up", "arrow.triangle.2.circlepath", "checklist", "person.2", "bolt",
        "doc.text", "newspaper", "megaphone", "chart.pie", "dollarsign.circle", "creditcard",
        "server.rack", "globe", "shield.lefthalf.filled", "lock", "photo", "paperplane"
    ]

    /// True for a well-formed name this Mac can draw. A missing symbol draws nothing, so it is never saved or shown.
    static func exists(_ name: String) -> Bool {
        AutomationSymbol.isWellFormed(name) && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The symbol to draw: `name` when it exists, otherwise the default.
    static func valid(_ name: String?) -> String {
        guard let name, exists(name) else { return AutomationSymbol.fallback }
        return name
    }
}

/// Model suggestions per runner. Empty uses the CLI's default.
