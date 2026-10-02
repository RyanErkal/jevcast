import LauncherCore

/// Prepared names avoid repeating Unicode and CamelCase work while typing.
struct AppSearchIndex {
    private struct Entry {
        let title: String
        let aliases: [String]
        let candidate: SearchRanking.Candidate
    }
    private var entries: [String: Entry] = [:]

    mutating func score(_ app: AppEntry, query: SearchRanking.Query, settings: SettingsQuery, aliases: [String]) -> Double? {
        let isPane = app.launchURL != nil
        let appQuery = settings.pane.map { SearchRanking.Query(literal: $0.literal + " settings") } ?? query
        guard let effectiveQuery = isPane ? settings.pane : appQuery else { return nil }
        let title = isPane && app.name.hasSuffix(" Settings") ? String(app.name.dropLast(" Settings".count)) : app.name
        let names = aliases + (app.bundleID == "com.apple.systempreferences" ? ["settings", "system preferences", "preferences"] : [])
        let cached = entries[app.id]
        let candidate: SearchRanking.Candidate
        if let cached, cached.title == title, cached.aliases == names { candidate = cached.candidate }
        else {
            candidate = SearchRanking.Candidate(title: title, aliases: names, style: .name)
            entries[app.id] = Entry(title: title, aliases: names, candidate: candidate)
        }
        guard let score = SearchRanking.score(query: effectiveQuery, candidate: candidate), !isPane || score >= 0.5 else { return nil }
        return score
    }

    mutating func retain(_ ids: Set<String>) { entries = entries.filter { ids.contains($0.key) } }
}
