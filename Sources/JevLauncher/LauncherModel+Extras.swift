import AppKit
import LauncherCore

/// Workflows, Shortcuts, snippets, timers, menu items, emoji, calculator history,
/// and open-then-arrange rows.
extension LauncherModel {
    // MARK: Modes that replace the normal list

    /// Rows for a query that asks for one kind of thing only, or nil for a normal search.
    func exclusiveRows(_ q: String) -> [LauncherResult]? {
        guard !isFileSearch else { return nil }
        if let prefix = Self.prefix(for: q) { return prefixRows(prefix) }
        if let search = Symbols.query(q) {
            return Symbols.search(search).enumerated().map { index, entry in
                LauncherResult(id: "symbol:" + entry.character, title: entry.character + "  " + entry.name.capitalized,
                               detail: "Return copies · ⇧Return pastes", symbol: "face.smiling", action: .copy(entry.character), score: 1000 - Double(index))
            }
        }
        let lower = q.lowercased()
        if ["timers", "timer list", "my timers", "cancel timer", "cancel timers"].contains(lower) {
            return timers.active.enumerated().map { index, timer in
                LauncherResult(id: "cancel:" + timer.id, title: "Cancel " + timer.title,
                               detail: "Ends " + timer.fires.formatted(date: .omitted, time: .shortened),
                               symbol: "timer", action: .cancelTimer(timer.id), score: 1000 - Double(index))
            }
        }
        if ["ans", "answers", "calc history", "calculator history", "history"].contains(lower), !answers.isEmpty {
            return answers.enumerated().map { index, answer in
                LauncherResult(id: "answer:\(index)", title: answer, detail: index == 0 ? "Last answer · use “ans” in a sum" : "Earlier answer",
                               symbol: "equal.square", action: .copy(answer), score: 1000 - Double(index))
            }
        }
        return nil
    }

    // MARK: Extra rows in a normal search

    func extraRows(_ q: String) -> [LauncherResult] {
        var rows: [LauncherResult] = []
        for workflow in preferences.workflows {
            guard let score = SearchRanking.score(query: q, title: workflow.name) else { continue }
            rows.append(workflowRow(workflow, score: score * 100))
        }
        for name in ShortcutsCatalogue.shared.names {
            guard let score = SearchRanking.score(query: q, title: name) else { continue }
            rows.append(shortcutRow(name, score: score * 100 - 2))
        }
        for snippet in preferences.snippets {
            guard let score = SearchRanking.score(query: q, title: snippet.name) else { continue }
            rows.append(snippetRow(snippet, score: score * 100))
        }
        if q.count >= 3 {
            let matches = menuCommands.compactMap { command -> LauncherResult? in
                guard let score = SearchRanking.score(query: q, title: command.title), score >= 0.7 else { return nil }
                return menuRow(command, score: score * 100 - 8)
            }
            rows += matches.sorted { $0.score > $1.score }.prefix(8)
        }
        if let timer = TimerQuery.parse(q) {
            let title = "Start \(TimerQuery.describe(timer.seconds)) timer" + (timer.label.isEmpty ? "" : ": " + timer.label)
            rows.append(LauncherResult(id: "timer", title: title, detail: "Notification when it ends", symbol: "timer",
                                       action: .timer(timer), score: 1850))
        }
        if let row = naturalQuicklinkRow(q) { rows.append(row) }
        if let create = CreateQuery.parse(q) { rows.append(createRow(create)) }
        rows += contextRows(q) + askRows(q) + taskRows(q)
        if let custom = customSelectionRow(q) { rows.append(custom) }
        return rows
    }

    /// A row for a stored ID from these sources, or nil.
    func extraRow(id: String) -> LauncherResult? {
        if id.hasPrefix("workflow:") {
            return preferences.workflows.first { "workflow:" + $0.id == id }.map { workflowRow($0, score: 0) }
        }
        if id.hasPrefix("shortcut:") {
            let name = String(id.dropFirst("shortcut:".count))
            return ShortcutsCatalogue.shared.names.contains(name) ? shortcutRow(name, score: 0) : nil
        }
        if id.hasPrefix("snippet:") {
            return preferences.snippets.first { "snippet:" + $0.id == id }.map { snippetRow($0, score: 0) }
        }
        if id.hasPrefix("open:") {
            let parts = id.dropFirst("open:".count).split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let app = catalogue.entries.first(where: { $0.id == parts[0] }),
                  let action = WindowAction(rawValue: parts[1]) else { return nil }
            return compoundRow(app, action, score: 0)
        }
        return nil
    }

    func workflowRow(_ workflow: Workflow, score: Double) -> LauncherResult {
        LauncherResult(id: "workflow:" + workflow.id, title: workflow.name, detail: "Workflow · \(workflow.steps.count) steps",
                       symbol: "list.bullet.rectangle", action: .workflow(workflow), score: score)
    }
    func shortcutRow(_ name: String, score: Double) -> LauncherResult {
        LauncherResult(id: "shortcut:" + name, title: name, detail: "Shortcut", symbol: "square.stack.3d.up", action: .shortcut(name), score: score)
    }
    func snippetRow(_ snippet: Snippet, score: Double) -> LauncherResult {
        LauncherResult(id: "snippet:" + snippet.id, title: snippet.name, detail: "Snippet · ⇧Return pastes", symbol: "text.quote",
                       action: .snippet(snippet), score: score)
    }
    func menuRow(_ command: MenuCommand, score: Double) -> LauncherResult {
        let detail = command.shortcut.isEmpty ? command.path : command.path + "  " + command.shortcut
        return LauncherResult(id: command.id, title: command.title, detail: detail, symbol: "filemenu.and.selection",
                              action: .menu(command), score: score)
    }

    // MARK: Open, then arrange

    func compoundRow(_ app: AppEntry, _ action: WindowAction, score: Double) -> LauncherResult {
        LauncherResult(id: "open:\(app.id)|\(action.rawValue)", title: "Open \(app.name) in \(action.title)", detail: "Open and arrange",
                       symbol: action.symbol, action: .appThenWindow(app, action), score: score)
    }

    /// An installed app that is not running, named in the query as whole words.
    func namedClosedApp(in q: String) -> AppEntry? {
        let running = Set(catalogue.runningApplications.compactMap(\.bundleURL).map(\.path))
        let apps = catalogue.entries.filter { $0.launchURL == nil && !running.contains($0.path) }
        let aliasesByApp = self.aliasesByApp
        let names = apps.map { (name: $0.name, aliases: aliasesByApp[$0.id] ?? []) }
        return Self.namedTargetIndex(in: q, apps: names).map { apps[$0] }
    }

    /// The window action whose name or alias appears in the query as whole words, longest first.
    func namedWindowAction(in q: String) -> WindowAction? {
        let phrase = " " + q.lowercased().split(separator: " ").joined(separator: " ") + " "
        let options = WindowAction.allCases.flatMap { action in ([action.title] + action.aliases).map { ($0.lowercased(), action) } }
        return options.filter { $0.0.count > 2 && phrase.contains(" " + $0.0 + " ") }.max { $0.0.count < $1.0.count }?.1
    }

    /// "notes left half" when Notes is not running: open Notes, then arrange it.
    func compoundRows(_ q: String, among rows: [LauncherResult]) -> [LauncherResult] {
        guard q.contains(" "), let app = namedClosedApp(in: q), let action = namedWindowAction(in: q) else { return [] }
        let windowScore = rows.first { $0.id == "window:" + action.rawValue }?.score ?? 90
        return [compoundRow(app, action, score: max(windowScore, 90) + 2)]
    }

    /// Turns a Jev pick of an app or a window action into open-then-arrange when the query names both.
    func compoundUpgrade(_ row: LauncherResult) -> LauncherResult? {
        switch row.action {
        case .window(let action, _):
            guard let app = namedClosedApp(in: query) else { return nil }
            return compoundRow(app, action, score: row.score)
        case .app(let app) where app.launchURL == nil:
            guard let action = namedWindowAction(in: query) else { return nil }
            let running = catalogue.runningApplications.contains { $0.bundleURL?.path == app.path }
            return running ? nil : compoundRow(app, action, score: row.score)
        default: return nil
        }
    }

    func openThenArrange(_ app: AppEntry, _ action: WindowAction) {
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        Frontmost.openApplication(at: URL(fileURLWithPath: app.path), configuration: config) { [weak self] running, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.showFailure(error.localizedDescription); return }
                guard let pid = running?.processIdentifier else { return }
                await self.arrangeWhenReady(action, pid: pid, appName: app.name)
            }
        }
    }

    /// Waits up to five seconds for a new app's first window, then arranges it.
    func arrangeWhenReady(_ action: WindowAction, pid: pid_t, appName: String) async {
        var lastError: Error?
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            do { try windows.execute(action, appPID: pid); return } catch { lastError = error }
            if case WindowManagerError.accessibilityPermissionRequired = lastError! { break }
        }
        showFailure("\(appName) opened, but its window could not be arranged: \(lastError?.localizedDescription ?? "no window").")
    }

    // MARK: Site search in plain words

    /// "search github for swift ui" and "look up moon on wikipedia" without Jev.
    func naturalQuicklinkRow(_ q: String) -> LauncherResult? {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard words.count >= 3, ["search", "look", "find", "lookup"].contains(words[0]) else { return nil }
        for link in preferences.quicklinks {
            let names = [link.name.lowercased(), link.keyword.lowercased()]
            guard names.contains(where: { name in (" " + words.joined(separator: " ") + " ").contains(" " + name + " ") }) else { continue }
            return naturalQuicklink("quicklink:" + link.id, score: 1700)
        }
        return nil
    }

    /// The site search row with the request's own words as the search text.
    func naturalQuicklink(_ id: String, score: Double = 0) -> LauncherResult? {
        guard let link = preferences.quicklinks.first(where: { "quicklink:" + $0.id == id }) else { return nil }
        if let keyword = Quicklink.match(query, in: preferences.quicklinks), keyword.link.id == link.id { return nil }
        let text = QueryText.remainder(of: query, removing: [link.name, link.keyword])
        guard !text.isEmpty, let url = link.url(for: text) else { return nil }
        return LauncherResult(id: id, title: "Search \(link.name) for \(text)", detail: Self.hostDetail(url), symbol: "link", action: .url(url), score: score)
    }

    // MARK: Running

    func runShortcut(_ name: String) {
        Task { [weak self] in
            do { try await CommandRunner.runShortcut(name) }
            catch { self?.showFailure("\(name): \(error.localizedDescription)") }
        }
    }

    func start(_ timer: TimerQuery) {
        Task { [weak self] in
            guard let self else { return }
            if let failure = await self.timers.start(timer) { self.showFailure(failure) }
        }
    }

    /// Presses a menu item after the launcher closes and the app is in front again.
    func pressLater(_ command: MenuCommand) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !MenuScanner.press(command) { self.showFailure("\(command.title) is not available any more.") }
        }
    }

    /// Runs each step in order. A window step arranges the app the step before it opened.
    func run(_ workflow: Workflow) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lastApp: (pid: pid_t, name: String)?
            for step in workflow.steps {
                do {
                    switch step.kind {
                    case .app:
                        guard let app = self.catalogue.entries.first(where: { $0.id == step.value }) else {
                            throw LauncherError("An app in \(workflow.name) is no longer installed.")
                        }
                        if let url = app.launchURL.flatMap(URL.init(string:)) { Frontmost.open(url); continue }
                        let config = NSWorkspace.OpenConfiguration(); config.activates = true
                        let running = try await Frontmost.openApplication(at: URL(fileURLWithPath: app.path), configuration: config)
                        lastApp = (running.processIdentifier, app.name)
                    case .window:
                        guard let action = WindowAction(rawValue: step.value) else { continue }
                        if let lastApp { await self.arrangeWhenReady(action, pid: lastApp.pid, appName: lastApp.name) }
                        else { try self.windows.execute(action, appPID: nil) }
                    case .command:
                        guard let command = SystemCommands.command(id: step.value) else { continue }
                        _ = try await CommandRunner.run(command)
                    case .custom:
                        guard let command = self.preferences.customCommands.first(where: { $0.id == step.value }) else { continue }
                        _ = try await CommandRunner.run(command)
                    case .shortcut:
                        try await CommandRunner.runShortcut(step.value)
                    case .wait:
                        let seconds = min(max(Double(step.value) ?? 1, 0), 30)
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    }
                } catch {
                    self.showFailure("\(workflow.name) stopped: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    // MARK: Menu items

    func loadMenuCommands(for app: NSRunningApplication) {
        guard app.processIdentifier != getpid(), app.activationPolicy == .regular else { return }
        let current = revision
        let name = app.localizedName ?? "App"
        Task { [weak self] in
            let found = await MenuScanner.scan(pid: app.processIdentifier, appName: name)
            guard let self, self.visible else { return }
            self.menuCommands = found
            if self.revision == current, !self.query.isEmpty { self.rebuild() }
        }
    }

    func acceptsSpeechAfterRoute() {
        acceptsSpeech = false
        speech.stop()
    }
}

/// Pastes into the app in front, after the launcher has closed. Needs Accessibility access.
@MainActor
enum Paster {
    static func pasteSoon() {
        guard AXIsProcessTrusted() else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }
}
