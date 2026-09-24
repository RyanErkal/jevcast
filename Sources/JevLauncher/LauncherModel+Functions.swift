import AppKit
import LauncherCore

/// "/" lists what the launcher can do; "$" lists the user's own library.
extension LauncherModel {
    var prefixQuery: PrefixQuery? { Self.prefix(for: query) }

    /// The prefix in `text`, unless it names a top-level folder such as "/tmp" or "/Applications".
    /// Exact case is always a path; other case is a path only when no function matches.
    nonisolated static func prefix(for text: String, root: Set<String> = rootEntries) -> PrefixQuery? {
        guard let prefix = PrefixQuery.parse(text) else { return nil }
        if case .functions(let rest) = prefix, !rest.isEmpty {
            if root.contains(rest) { return nil }
            if root.contains(where: { $0.caseInsensitiveCompare(rest) == .orderedSame }),
               FunctionCatalog.search(rest, in: FunctionCatalog.builtIn).isEmpty { return nil }
        }
        return prefix
    }
    nonisolated static let rootEntries = Set((try? FileManager.default.contentsOfDirectory(atPath: "/")) ?? [])

    /// Rows for a "/" or "$" query, grouped with section labels.
    func prefixRows(_ prefix: PrefixQuery) -> [LauncherResult] {
        let library = libraryItems
        let rowsByID = Dictionary(library.map { ($0.entry.id, $0.row) }, uniquingKeysWith: { first, _ in first })
        let libraryEntries = library.map(\.entry)
        let entries: [FunctionEntry]
        switch prefix {
        case .functions: entries = FunctionCatalog.views + FunctionCatalog.lists + FunctionCatalog.commands
            + FunctionCatalog.settings + libraryEntries + FunctionCatalog.windows
        case .library where library.isEmpty: entries = FunctionCatalog.settings.filter { $0.id == "settings:library" }
        case .library: entries = libraryEntries
        }
        let found = FunctionCatalog.search(prefix.filter, in: entries)
        let rows: [LauncherResult] = found.enumerated().compactMap { index, entry in
            guard var row = rowsByID[entry.id] ?? functionRow(entry) else { return nil }
            row.score = 1000 - Double(index)
            row.section = .named(entry.group.rawValue)
            // Library rows keep their kind; window rows keep the app they move.
            if entry.group != .library && entry.group != .windows { row.detail = entry.summary }
            return row
        }
        // "$AAPL" with no library match still offers the web, for the words after the prefix.
        if rows.isEmpty, !prefix.filter.isEmpty, let web = webRow(prefix.filter) { return [web] }
        return rows
    }

    func webRow(_ q: String) -> LauncherResult? {
        var components = URLComponents(string: preferences.webEngine == "DuckDuckGo" ? "https://duckduckgo.com/" : "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: q)]
        return components.url.map { LauncherResult(id: "web", title: "Search " + preferences.webEngine, detail: Self.hostDetail($0), symbol: "magnifyingglass", action: .url($0), score: -1000) }
    }

    /// Tab puts the selected row's name after the prefix. Returns true whenever a prefix is
    /// typed, so Tab never moves focus out of the field; a name that would leave the mode is refused.
    func completePrefix() -> Bool {
        guard let prefix = prefixQuery else { return false }
        guard let row = selected ?? results.first(where: \.isCurrent), row.id != "web" else { return true }
        let isLibrary = if case .library = prefix { true } else { false }
        let completed = (isLibrary ? "$" : "/") + row.title
        let kept = Self.prefix(for: completed).map { if case .library = $0 { isLibrary } else { !isLibrary } } ?? false
        guard kept else { return true }
        updateQuery(completed, typed: true)
        select(row.id)
        return true
    }

    /// The ID of a view row, such as "view:mail", when the app can show views.
    func viewID(_ result: LauncherResult) -> String? {
        result.id.hasPrefix("view:") && openView != nil ? String(result.id.dropFirst("view:".count)) : nil
    }

    /// The user's commands, workflows, and snippets with their rows, built once per list.
    private var libraryItems: [(entry: FunctionEntry, row: LauncherResult)] {
        func item(_ row: LauncherResult, _ summary: String) -> (FunctionEntry, LauncherResult) {
            (FunctionEntry(id: row.id, title: row.title, summary: summary, symbol: row.symbol, group: .library), row)
        }
        return preferences.customCommands.map { item(Self.customRow($0, score: 0), "Your command") }
            + preferences.workflows.map { item(workflowRow($0, score: 0), "Workflow") }
            + preferences.snippets.map { item(snippetRow($0, score: 0), "Snippet") }
    }

    /// A runnable row for a catalogue entry. Every action is fixed code; nothing becomes shell text.
    private func functionRow(_ entry: FunctionEntry) -> LauncherResult? {
        let (kind, value) = entry.id.split(separator: ":", maxSplits: 1).map(String.init).splitPair
        switch kind {
        case "command": return commandRow(id: entry.id, score: 0)
        case "window":
            return WindowAction(rawValue: value).map { windowRow($0, target: nil, score: 0) }
        case "source":
            return LauncherResult(id: entry.id, title: entry.title, detail: "", symbol: entry.symbol, action: .route(Self.sourceRoutes[value] ?? entry.title.lowercased()), score: 0)
        case "view":
            if value == "mail" {
                return verbRow(entry, "Open Mail") { [weak self] in self?.openMail?(nil); return nil }
            }
            // Without views, each opens its list in the launcher.
            return LauncherResult(id: entry.id, title: entry.title, detail: "", symbol: entry.symbol, action: .route(Self.viewRoutes[value] ?? value), score: 0)
        case "settings":
            return verbRow(entry, "Open Settings") { [weak self] in self?.openSettingsTab?(value); return nil }
        default: return nil
        }
    }

    private static let viewRoutes = ["calendar": "calendar", "tasks": "luna tasks", "clipboard": "clip ", "cleanup": "clean up"]
    private static let sourceRoutes = ["reminders": "reminders ", "scheduled": "scheduled tasks", "taskRuns": "task results", "contacts": "contacts ", "tabs": "tabs ", "history": "browser history ", "help": "help"]

    private func verbRow(_ entry: FunctionEntry, _ title: String, run: @escaping @MainActor () async throws -> String?) -> LauncherResult {
        LauncherResult(id: entry.id, title: entry.title, detail: "", symbol: entry.symbol,
                       action: .thing(Thing(verbs: [Verb(title: title, run: run)], twoLine: false)), score: 0)
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
