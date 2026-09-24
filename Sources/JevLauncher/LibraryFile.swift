import Foundation

/// The user's own items as one JSON file, for Settings › Library › Export and Import.
/// Import only adds items that are not there yet, matched by ID, and never runs anything.
struct LibraryFile: Codable, Equatable {
    var version = 1
    var commands: [CustomCommand] = []
    var workflows: [Workflow] = []
    var snippets: [Snippet] = []
    var keywords: [Quicklink] = []
    var aliases: [String: String] = [:]

    init(commands: [CustomCommand] = [], workflows: [Workflow] = [], snippets: [Snippet] = [],
         keywords: [Quicklink] = [], aliases: [String: String] = [:]) {
        self.commands = commands; self.workflows = workflows; self.snippets = snippets
        self.keywords = keywords; self.aliases = aliases
    }
    @MainActor init(_ preferences: Preferences) {
        self.init(commands: preferences.customCommands, workflows: preferences.workflows, snippets: preferences.snippets,
                  keywords: preferences.quicklinks, aliases: preferences.aliases)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    static func decode(_ data: Data) throws -> LibraryFile {
        let file = try JSONDecoder().decode(LibraryFile.self, from: data)
        guard file.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return file
    }

    var count: Int { commands.count + workflows.count + snippets.count + keywords.count + aliases.count }

    /// The items import would add: new IDs and names only, each once, and only valid keywords.
    /// `skipped` counts the rest.
    @MainActor func additions(to preferences: Preferences) -> (file: LibraryFile, skipped: Int) {
        func fresh<T: Identifiable>(_ items: [T], _ existing: [T], name: (T) -> String) -> [T] where T.ID == String {
            var ids = Set(existing.map(\.id))
            var names = Set(existing.map { name($0).lowercased() })
            return items.filter { item in
                let key = name(item).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, ids.insert(item.id).inserted, names.insert(key).inserted else { return false }
                return true
            }
        }
        var keywords: [Quicklink] = []
        for link in self.keywords where Quicklink.validationError(keyword: link.keyword, template: link.template,
                                                                  existing: preferences.quicklinks + keywords) == nil {
            keywords.append(link)
        }
        let apps = Set(preferences.aliases.keys.map { $0.lowercased() })
        var file = LibraryFile(
            commands: fresh(commands.filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, preferences.customCommands, name: \.name),
            workflows: fresh(workflows, preferences.workflows, name: \.name),
            snippets: fresh(snippets, preferences.snippets, name: \.name),
            keywords: keywords)
        for (alias, app) in aliases where !apps.contains(alias.lowercased()) && !alias.contains(where: \.isWhitespace) {
            if !file.aliases.keys.contains(where: { $0.lowercased() == alias.lowercased() }) { file.aliases[alias] = app }
        }
        return (file, count - file.count)
    }

    /// Adds the items from `additions(to:)`, which the user has seen, and returns how many.
    @MainActor func merge(into preferences: Preferences) -> Int {
        let new = additions(to: preferences).file
        if !new.commands.isEmpty { preferences.customCommands += new.commands }
        if !new.workflows.isEmpty { preferences.workflows += new.workflows }
        if !new.snippets.isEmpty { preferences.snippets += new.snippets }
        if !new.keywords.isEmpty { preferences.quicklinks += new.keywords }
        if !new.aliases.isEmpty { preferences.aliases.merge(new.aliases) { current, _ in current } }
        return new.count
    }
}
