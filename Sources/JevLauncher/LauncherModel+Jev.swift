import AppKit
import LauncherCore

/// How the launcher uses Jev: local answers first, then memory, then one request per
/// settled phrase. Jev only ever picks an ID from the list below.
extension LauncherModel {
    static let jevCandidateLimit = 120
    static let portsCandidateID = "ports"
    /// Rows at or above this score are a definite answer: a sum, a typed URL, a keyword search, a timer, or a port.
    static let definiteScore = 1000.0
    /// A whole-name match scores 100. Jev is not asked then.
    static let exactScore = 100.0
    static let replyLifetime: TimeInterval = 600
    /// Special candidates that change the query instead of running something.
    static let routes: [(id: String, title: String, detail: String, query: (String) -> String)] = [
        ("route:files", "Find files", "Search files and folders by name, kind, folder, and date", { "find " + $0 }),
        ("route:recent", "Recent files", "List the files changed most recently", { _ in "recent files" }),
        ("route:clip", "Clipboard history", "Show text the user copied earlier", { _ in "clip" }),
        ("route:timers", "Running timers", "Show and cancel timers", { _ in "timers" }),
        ("route:scheduled", "Scheduled tasks", "Show what runs on a schedule or in the background: launch agents, daemons, cron jobs, login items, and timers", { _ in "scheduled tasks" }),
        ("route:calendar", "Calendar events", "Show upcoming events and meetings, and join video calls", { _ in "calendar" }),
        ("route:reminders", "Reminders", "Show open reminders and to-dos, and complete them", { _ in "reminders" }),
        ("route:cleanup", "Clean up background work", "Stop idle dev servers, leftover processes, and simulators to free memory and cool the Mac", { _ in "cleanup" }),
        ("route:mail", "Mail", "Open the mail inbox, read unread email, or search email", { _ in "mail" }),
        ("route:tabs", "Open browser tabs", "Find, switch to, or close tabs open in the web browser", { _ in "tabs" }),
        ("route:contacts", "Find a contact", "Find a person to email, message, or call", { q in "contact " + QueryText.remainder(of: q, removing: ["contact", "email", "call", "message", "text", "phone"]) })
    ]

    /// Called after every change to the query. Waits for a pause, then answers from
    /// memory or asks Jev. Skips requests that already have one clear local answer.
    func scheduleJev(_ trimmed: String, revision current: UUID) {
        guard !isFileSearch, !isClipboardSearch, portQuery == nil, sourceQuery == nil, trimmed.count >= 2 else { return }
        let top = results.first(where: \.isCurrent)?.score ?? 0
        guard top < Self.exactScore else { return }
        // Memory needs no key and no network, so it works even with Jev off.
        if let id = preferences.learned.lookup(trimmed), canResolve(id) {
            aiWork = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self, self.revision == current else { return }
                self.aiStatus = "Remembered"
                self.usage?.recordSaved()
                self.promote(id, remembered: true)
            }
            return
        }
        guard preferences.jevEnabled, top < Self.definiteScore else { return }
        let key = LearnedIntents.normalize(trimmed)
        if let cached = replyCache[key], Date().timeIntervalSince(cached.at) < Self.replyLifetime {
            if let id = cached.id, canResolve(id) {
                aiStatus = "Jev matched"
                promote(id, remembered: false)
            }
            return
        }
        aiWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self, self.revision == current else { return }
            await self.interpret(trimmed, revision: current)
        }
    }

    func interpret(_ text: String, revision current: UUID) async {
        let key: String
        switch await keys.load() {
        case .present(let value): key = value
        case .failed(let message): if revision == current && visible { aiStatus = message; aiError = message }; return
        case .missing, .unknown:
            if revision == current && visible { aiStatus = "Add a Jev key in Settings"; aiError = "Add a TypeSafe or OpenRouter key in Settings › Input." }
            return
        }
        guard !Task.isCancelled, visible, revision == current else { return }
        let (candidates, ids) = jevCandidates()
        aiStatus = Self.interpreting
        do {
            let chosen = try await preferences.jevLayered
                ? layeredChoice(text, candidates: candidates, ids: ids, key: key, revision: current)
                : jev.choose(query: text, candidates: candidates, apiKey: key).flatMap { ids[$0] }
            guard !Task.isCancelled, visible, self.revision == current else { return }
            // A pick that moves an app Jev chose is not cached: the ID alone would move the active window.
            if jevWindowTarget == nil { replyCache[LearnedIntents.normalize(text)] = (chosen, Date()) }
            aiStatus = chosen == nil ? "No clear AI match" : "Jev matched"
            guard let chosen else { return }
            // A whole-name match the user typed stays first.
            if let top = results.first(where: \.isCurrent), top.score >= Self.exactScore, top.id != chosen, !chosen.hasPrefix("route:"), chosen != Self.portsCandidateID {
                aiStatus = "Kept exact match"; return
            }
            usage?.recordMatch()
            promote(chosen, remembered: false)
        } catch {
            guard !Task.isCancelled, visible, revision == current else { return }
            aiStatus = JevService.statusMessage(for: error); aiError = aiStatus
        }
    }

    /// Candidates for Jev under opaque IDs. The list puts what matches the request's words first,
    /// then every action, then likely apps. No path or command text appears in any ID, title, or detail.
    func jevCandidates() -> (candidates: [JevCandidate], ids: [String: String]) {
        Self.opaque(jevEntries(limit: Self.jevCandidateLimit))
    }

    static func opaque(_ entries: [(id: String, title: String, detail: String)]) -> (candidates: [JevCandidate], ids: [String: String]) {
        var ids: [String: String] = [:]
        let candidates = entries.enumerated().map { index, entry in
            ids["c\(index)"] = entry.id
            return JevCandidate(id: "c\(index)", title: entry.title, detail: entry.detail)
        }
        return (candidates, ids)
    }

    func jevEntries(limit: Int) -> [(id: String, title: String, detail: String)] {
        var entries: [(id: String, title: String, detail: String)] = []
        var included = Set<String>()
        func add(_ id: String, _ title: String, _ detail: String) {
            guard entries.count < limit, included.insert(id).inserted else { return }
            entries.append((id, title, detail))
        }
        // 1. What is on screen now.
        for row in results where row.isCurrent {
            if let described = Self.jevDescription(row) { add(row.id, described.title, described.detail) }
        }
        // 2. Things the request's words point at, from every source.
        let pool = jevPool()
        let words = LearnedIntents.normalize(query).split(separator: " ").map(String.init).filter { $0.count >= 3 }
        var relevant: [(index: Int, score: Double)] = []
        for (index, entry) in pool.enumerated() {
            var best = 0.0
            for word in words { best = max(best, SearchRanking.score(query: word, title: entry.title) ?? 0) }
            if best >= 0.6 { relevant.append((index, best)) }
        }
        relevant.sort { $0.score > $1.score }
        for item in relevant.prefix(40) { let entry = pool[item.index]; add(entry.id, entry.title, entry.detail) }
        // 3. Every action, so loose phrasing still has a target.
        for action in WindowAction.allCases { add("window:" + action.rawValue, action.title, "Arrange the active window") }
        for command in SystemCommands.all { add("command:" + command.id, command.title, command.detail) }
        add(Self.portsCandidateID, "Stop the process on a port", "Find the app or server listening on a local TCP port and stop it")
        for route in Self.routes { add(route.id, route.title, route.detail) }
        if lunaReady { add(Self.askID, "Ask Luna", "Answer a question, explain something, or write new text with the Luna writing model") }
        if let custom = customSelectionRow(query) { add(custom.id, custom.title, "Apply the typed instruction to the text selected in the front app, with the Luna writing model") }
        for row in allContextRows() {
            if case .thing(let thing) = row.action, let detail = thing.jevDetail { add(row.id, row.title, detail) }
        }
        for command in preferences.customCommands { add("custom:" + command.id, command.name, "Run the user's own command") }
        for workflow in preferences.workflows { add("workflow:" + workflow.id, workflow.name, "Run the user's saved workflow") }
        for link in preferences.quicklinks {
            add("quicklink:" + link.id, "Search " + link.name, "Search the website \(link.name) for the topic in the request, such as issues, videos, places, or articles")
        }
        // 4. The rest of the pool, likely apps first.
        for entry in pool { add(entry.id, entry.title, entry.detail) }
        return entries
    }

    // MARK: Layers

    /// Most candidates one step can send. TypeSafe allows 254 plus no_match.
    static let layerLimit = 250

    func jevKind(of id: String, settingsPanes: Set<String>? = nil) -> JevKind? {
        JevKind.of(id, isSettingsPane: (settingsPanes ?? Set(catalogue.entries.filter { $0.launchURL != nil }.map(\.id))).contains(id))
    }

    /// Two quick questions at once: the single-list pick, and which kind of request this is. When
    /// they agree, the pick stands at no extra wait. When they differ, Jev chooses again among
    /// every candidate of that kind. A window move that names an app asks which app, last.
    func layeredChoice(_ text: String, candidates: [JevCandidate], ids: [String: String], key: String, revision current: UUID) async throws -> String? {
        let everything = jevEntries(limit: .max)
        // One lookup per candidate, not one per kind.
        let panes = Set(catalogue.entries.filter { $0.launchURL != nil }.map(\.id))
        let kindOf = Dictionary(everything.map { ($0.id, jevKind(of: $0.id, settingsPanes: panes)) }, uniquingKeysWith: { first, _ in first })
        let present = Set(kindOf.values.compactMap { $0 })
        let kinds = JevKind.allCases.filter(present.contains)
        var kindIDs: [String: JevKind] = [:]
        let kindCandidates = kinds.enumerated().map { index, kind -> JevCandidate in
            kindIDs["k\(index)"] = kind
            return JevCandidate(id: "k\(index)", title: kind.title, detail: kind.detail)
        }
        async let flat = jev.choose(query: text, candidates: candidates, apiKey: key)
        async let layer = jev.choose(query: text, candidates: kindCandidates, apiKey: key)
        let pick = try await flat.flatMap { ids[$0] }
        // The kind step is a check. If it fails, the single-list answer stands on its own.
        let kind = ((try? await layer) ?? nil).flatMap { kindIDs[$0] }
        guard !Task.isCancelled, visible, revision == current else { return nil }
        var chosen: String?
        switch JevLayerPlan.decide(pick: pick, pickKind: pick.flatMap { kindOf[$0] ?? jevKind(of: $0, settingsPanes: panes) }, kind: kind) {
        case .accept(let id): chosen = id
        case .noMatch: chosen = nil
        case .narrow(let kind):
            // Jev always makes the second choice, even from one candidate, so it can still say no match.
            let narrowed = Array(everything.filter { kindOf[$0.id] == kind }.prefix(Self.layerLimit))
            if !narrowed.isEmpty {
                let (second, secondIDs) = Self.opaque(narrowed)
                chosen = try await jev.choose(query: text, candidates: second, apiKey: key).flatMap { secondIDs[$0] }
            }
        }
        if let id = chosen, id.hasPrefix("window:"), let action = WindowAction(rawValue: String(id.dropFirst(7))),
           let target = try await windowTarget(text, action: action, key: key),
           !Task.isCancelled, visible, revision == current {
            jevWindowTarget = target
        }
        return chosen
    }

    /// Which running app's window a request means, such as "put slack on the left", when no app
    /// name matched exactly. Nil keeps the active window.
    func windowTarget(_ text: String, action: WindowAction, key: String) async throws -> NSRunningApplication? {
        guard namedTarget(in: text) == nil else { return nil }
        let known = Set(([action.title] + action.aliases).flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        let spare = LearnedIntents.normalize(text).split(separator: " ").map(String.init)
            .filter { $0.count >= 3 && !known.contains($0) && !["the", "this", "that", "window", "move", "put", "make", "and", "screen", "half", "side"].contains($0) }
        guard !spare.isEmpty else { return nil }
        let apps = catalogue.runningApplications.filter { $0.processIdentifier != getpid() && $0.activationPolicy == .regular && $0.localizedName != nil }
        // Ask only when a word loosely names a running app, such as "chrom" or "the slack one".
        let hinted = apps.contains { app in spare.contains { SearchRanking.score(query: $0, title: app.localizedName ?? "") ?? 0 >= 0.6 } }
        guard apps.count > 1, hinted else { return nil }
        var byID: [String: NSRunningApplication] = [:]
        let options = apps.prefix(Self.layerLimit).enumerated().map { index, app -> JevCandidate in
            byID["a\(index)"] = app
            return JevCandidate(id: "a\(index)", title: app.localizedName ?? "App", detail: "The window of this running app")
        }
        return try await jev.choose(query: text, candidates: options, apiKey: key).flatMap { byID[$0] }
    }

    /// Apps, settings panes, Shortcuts, snippets, and menu items, with favourite, recent, and running apps first.
    private func jevPool() -> [(id: String, title: String, detail: String)] {
        var pool: [(id: String, title: String, detail: String)] = []
        pool += preferences.snippets.map { ("snippet:" + $0.id, $0.name, "Copy the user's saved text snippet") }
        pool += ShortcutsCatalogue.shared.names.map { ("shortcut:" + $0, $0, "Run an Apple Shortcut") }
        pool += menuCommands.prefix(150).map { ($0.id, $0.title, "Menu item in the front app: " + $0.path.replacingOccurrences(of: " › ", with: " > ")) }
        let running = Set(catalogue.runningApplications.compactMap(\.bundleURL).map(\.path))
        let likely = Set(preferences.favourites + preferences.recentIDs)
        let hidden = Set(preferences.hiddenApps)
        let apps = catalogue.entries.filter { !hidden.contains($0.id) }.sorted { lhs, rhs in
            let l = (likely.contains(lhs.id) ? 2 : 0) + (running.contains(lhs.path) ? 1 : 0)
            let r = (likely.contains(rhs.id) ? 2 : 0) + (running.contains(rhs.path) ? 1 : 0)
            return l != r ? l > r : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        pool += apps.map { ($0.id, $0.name, $0.launchURL != nil ? "Open this System Settings pane" : "Open installed application") }
        return pool
    }

    /// A row's title and Jev description, or nil for rows Jev should not see.
    private static func jevDescription(_ row: LauncherResult) -> (title: String, detail: String)? {
        switch row.action {
        case .app(let app): return (row.title, app.launchURL != nil ? "Open this System Settings pane" : "Open installed application")
        case .file(let file): return (file.name, file.isDirectory ? "Folder" : "File")
        case .window(let action, _): return (action.title, "Arrange the active window")
        case .url where row.id.hasPrefix("quicklink:"):
            let site = row.title.replacingOccurrences(of: "Search ", with: "").components(separatedBy: " for ").first ?? row.title
            return ("Search " + site, "Search the website \(site) for the topic in the request, such as issues, videos, places, or articles")
        case .command(let command): return (command.title, command.detail)
        case .custom(let command, nil): return (command.name, "Run the user's own command")
        case .appThenWindow(let app, let action): return ("Open \(app.name) in \(action.title)", "Open an app and arrange its window")
        case .shortcut(let name): return (name, "Run an Apple Shortcut")
        case .workflow(let workflow): return (workflow.name, "Run the user's saved workflow")
        case .snippet(let snippet): return (snippet.name, "Copy the user's saved text snippet")
        case .menu(let command): return (command.title, "Menu item in the front app")
        case .thing(let thing): return thing.jevDetail.map { (row.title, $0) }
        default: return nil
        }
    }

    func canResolve(_ id: String) -> Bool {
        if id == Self.portsCandidateID || Self.routes.contains(where: { $0.id == id }) { return true }
        if id.hasPrefix("menu:") { return menuCommands.contains { $0.id == id } }
        if results.contains(where: { $0.id == id }) { return true }
        if id == Self.askID { return lunaReady }
        if id == Self.customSelectionID { return customSelectionRow(query) != nil }
        if id.hasPrefix("this:") { return allContextRows().contains { $0.id == id } }
        if catalogue.entries.contains(where: { $0.id == id }) { return true }
        if id.hasPrefix("window:") { return WindowAction(rawValue: String(id.dropFirst(7))) != nil }
        if id.hasPrefix("quicklink:") { return preferences.quicklinks.contains { "quicklink:" + $0.id == id } }
        return commandRow(id: id, score: 0) != nil || extraRow(id: id) != nil
    }

    /// Puts a pick first. A pick outside the current rows is added, then the list regroups around it.
    /// Some picks become richer rows: an app plus a window layout, or a site search with the request's text.
    func promote(_ chosen: String, remembered: Bool) {
        if chosen == Self.portsCandidateID {
            loadPorts(PortQuery(port: PortQuery.firstPort(in: query)), revision: revision, promoteFirst: true)
            return
        }
        if let route = Self.routes.first(where: { $0.id == chosen }) {
            // The route changes the query, so stop voice from writing over it.
            acceptsSpeechAfterRoute()
            updateQuery(route.query(query), typed: false)
            return
        }
        // A window pick with an app Jev chose moves that app, not the active window.
        var row = (chosen.hasPrefix("window:") && jevWindowTarget != nil ? nil : results.first { $0.id == chosen }) ?? semanticRow(for: chosen)
        // "open notes on the left" and "notes left half": one pick becomes open, then arrange.
        if let base = row, let compound = compoundUpgrade(base) { row = compound }
        // "search github for swift ui": keep the request's words as the search.
        if let base = row, base.id.hasPrefix("quicklink:"), let upgraded = naturalQuicklink(base.id) { row = upgraded }
        guard let row else { return }
        semanticResult = results.contains(where: { $0.id == row.id && $0.title == row.title }) ? nil : row
        promotedID = row.id
        jevPick = (row.id, remembered)
        rebuild()
    }

    /// A row for an ID that is not on screen.
    private func semanticRow(for id: String) -> LauncherResult? {
        if let app = catalogue.entries.first(where: { $0.id == id }) {
            let running = catalogue.runningApplications.contains { $0.bundleURL?.path == app.path }
            return Self.appRow(app, running: running, score: 0)
        }
        if let action = WindowAction.allCases.first(where: { "window:" + $0.rawValue == id }) {
            return windowRow(action, target: jevWindowTarget ?? namedTarget(in: query), score: 0)
        }
        if id.hasPrefix("quicklink:"), let link = preferences.quicklinks.first(where: { "quicklink:" + $0.id == id }), let url = link.url(for: "") {
            return LauncherResult(id: id, title: "Search " + link.name, detail: Self.hostDetail(url), symbol: "link", action: .url(url), score: 0)
        }
        if let command = menuCommands.first(where: { $0.id == id }) { return menuRow(command, score: 0) }
        if id == Self.askID, lunaReady { return askRow(query.trimmingCharacters(in: .whitespaces), score: 0) }
        if id == Self.customSelectionID { return customSelectionRow(query) }
        if id.hasPrefix("this:") { return allContextRows().first { $0.id == id } }
        return commandRow(id: id, score: 0) ?? extraRow(id: id)
    }

    /// Undoes the last Jev or memory pick for this request, and forgets it.
    func undoJevPick() -> Bool {
        guard let jevPick else { return false }
        preferences.unlearn(query)
        replyCache[LearnedIntents.normalize(query)] = (nil, Date())
        self.jevPick = nil; promotedID = nil; semanticResult = nil; manualSelection = false
        aiStatus = jevPick.remembered ? "Forgot this answer" : "Jev pick undone"
        rebuild()
        return true
    }

    var jevNotice: String? {
        guard let jevPick, let row = results.first(where: { $0.id == jevPick.id }), selectedID == jevPick.id else { return nil }
        return (jevPick.remembered ? "Remembered: " : "Jev picked ") + row.title + ". Press ⌘Z to undo."
    }

    /// Remembers what a request meant when Jev or memory was involved, or when the user
    /// chose something other than the first row. A later identical request then skips Jev.
    func learnFromExecution(_ result: LauncherResult) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A Jev-chosen window target is not remembered: the ID alone would move the active window.
        guard !q.isEmpty, Self.isLearnable(result), jevWindowTarget == nil else { return }
        let firstRow = results.first(where: \.isCurrent)?.id
        let exact = (results.first(where: \.isCurrent)?.score ?? 0) >= Self.exactScore && firstRow == result.id
        guard !exact, jevPick != nil || result.id != firstRow || aiStatus == "No clear AI match" else { return }
        preferences.learn(q, id: result.id)
    }

    private static func isLearnable(_ result: LauncherResult) -> Bool {
        switch result.action {
        case .app, .window, .command, .shortcut, .workflow, .snippet, .file: return true
        case .custom(_, let input): return input == nil
        case .url: return result.id.hasPrefix("quicklink:")
        default: return false
        }
    }
}
