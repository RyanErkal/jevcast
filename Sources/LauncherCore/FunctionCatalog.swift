import Foundation

/// A search-field prefix that narrows the list: "/" for functions, "$" for the user's library.
public enum PrefixQuery: Equatable, Sendable {
    case functions(String)
    case library(String)

    /// "/cal" lists functions that match "cal"; "$deploy" lists library items. A second "/"
    /// makes the text a path, so "/Users/me" stays a file search. The app also keeps
    /// single-part paths such as "/tmp" as paths.
    public static func parse(_ text: String) -> PrefixQuery? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch first {
        case "/" where !rest.contains("/") && !rest.contains("~"): return .functions(rest)
        // "$120 to eur" is money, not the library.
        case "$" where !(rest.first?.isNumber ?? false): return .library(rest)
        default: return nil
        }
    }
    public var filter: String {
        switch self { case .functions(let text), .library(let text): return text }
    }
}

/// One thing the launcher can do, listed by "/" search.
public struct FunctionEntry: Identifiable, Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case views = "Views", lists = "Lists", commands = "Commands", windows = "Windows", settings = "Settings", library = "Library"
    }
    /// A launcher ID, such as "command:mute", "window:left-half", "view:mail", "source:scheduled", or "settings:ai".
    public let id: String
    public let title: String
    public let keywords: [String]
    /// One line that says what it does.
    public let summary: String
    public let symbol: String
    public let group: Group
    public init(id: String, title: String, keywords: [String] = [], summary: String, symbol: String, group: Group) {
        self.id = id; self.title = title; self.keywords = keywords; self.summary = summary; self.symbol = symbol; self.group = group
    }
}

/// Every built-in function. The app adds the user's commands, workflows, and snippets.
public enum FunctionCatalog {
    public static let views: [FunctionEntry] = [
        FunctionEntry(id: "view:mail", title: "Mail", keywords: ["inbox", "email"], summary: "Read and clear your Apple Mail inbox", symbol: "envelope", group: .views),
        FunctionEntry(id: "view:calendar", title: "Calendar", keywords: ["agenda", "events", "meetings", "my day"], summary: "Today's and upcoming events", symbol: "calendar", group: .views),
        FunctionEntry(id: "view:tasks", title: "Quill Tasks", keywords: ["scheduled quill", "task results", "quill"], summary: "Scheduled Quill tasks and what they wrote", symbol: "sparkles", group: .views),
        FunctionEntry(id: "view:clipboard", title: "Clipboard", keywords: ["clip", "clipboard history", "paste"], summary: "Text you copied earlier", symbol: "doc.on.clipboard", group: .views),
        FunctionEntry(id: "view:cleanup", title: "Clean Up", keywords: ["cleanup", "free memory", "cool down"], summary: "Quit or stop background work you choose", symbol: "leaf", group: .views)
    ]

    /// Source lists that have no view of their own.
    public static let lists: [FunctionEntry] = [
        FunctionEntry(id: "source:scheduled", title: "Scheduled Tasks", keywords: ["automations", "launchd", "cron", "login items"], summary: "Launch agents, cron jobs, timers, and Quill tasks", symbol: "clock.arrow.circlepath", group: .lists),
        FunctionEntry(id: "source:taskRuns", title: "Task Results", keywords: ["quill results", "task log"], summary: "What scheduled Quill tasks wrote", symbol: "doc.text.magnifyingglass", group: .lists),
        FunctionEntry(id: "source:reminders", title: "Reminders", keywords: ["todo", "to do", "tasks"], summary: "Open reminders", symbol: "checklist", group: .lists),
        FunctionEntry(id: "source:contacts", title: "Contacts", keywords: ["people"], summary: "Find a contact", symbol: "person.crop.circle", group: .lists),
        FunctionEntry(id: "source:tabs", title: "Browser Tabs", keywords: ["tabs", "open tabs"], summary: "Switch to an open browser tab", symbol: "safari", group: .lists),
        FunctionEntry(id: "source:history", title: "Browser History", keywords: ["web history"], summary: "Pages you visited", symbol: "clock", group: .lists),
        FunctionEntry(id: "source:help", title: "Help", keywords: ["what can you do"], summary: "What Jevcast can do", symbol: "questionmark.circle", group: .lists)
    ]

    public static let settings: [FunctionEntry] = [
        ("general", "General", "Permissions, shortcut, and network", "gearshape", ["permissions", "shortcut"]),
        ("search", "Search", "File folders, app aliases, hidden apps, and search keywords", "magnifyingglass", ["folders", "hide apps"]),
        ("library", "Library", "Your commands, workflows, and snippets", "books.vertical", ["commands", "workflows", "snippets"]),
        ("windows", "Windows", "Window gaps and shortcuts", "macwindow", ["gaps", "snapping"]),
        ("voice", "Voice", "Speech input", "waveform", ["microphone", "dictation"]),
        ("ai", "AI", "Jev, Quill, and usage", "sparkles", ["jev", "quill", "openrouter", "usage", "key"]),
        ("mail", "Mail", "Mail window options", "envelope", ["inbox"])
    ].map { id, title, summary, symbol, keywords in
        FunctionEntry(id: "settings:" + id, title: title + " Settings", keywords: keywords, summary: summary, symbol: symbol, group: .settings)
    }

    public static var commands: [FunctionEntry] {
        SystemCommands.all.map {
            FunctionEntry(id: "command:" + $0.id, title: $0.title, keywords: $0.aliases, summary: $0.detail, symbol: $0.symbol, group: .commands)
        }
    }
    public static var windows: [FunctionEntry] {
        WindowAction.allCases.map {
            FunctionEntry(id: "window:" + $0.rawValue, title: $0.title, keywords: $0.aliases, summary: windowSummary($0), symbol: $0.symbol, group: .windows)
        }
    }
    private static func windowSummary(_ action: WindowAction) -> String {
        switch action {
        case .tileAll: return "Tile every window on the display"
        case .cascadeAll: return "Cascade every window on the display"
        default: return "Move or resize the front window"
        }
    }
    public static var builtIn: [FunctionEntry] { views + lists + commands + settings + windows }

    /// Entries that match `filter` by title or keyword, best first. An empty filter keeps
    /// catalogue order. Ties keep group order.
    public static func search(_ filter: String, in entries: [FunctionEntry]) -> [FunctionEntry] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return entries }
        let scored = entries.enumerated().compactMap { index, entry -> (FunctionEntry, Double, Int)? in
            SearchRanking.score(query: text, title: entry.title, aliases: entry.keywords).map { (entry, $0, index) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }
}
