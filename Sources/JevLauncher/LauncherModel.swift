import AppKit
import Combine
import LauncherCore

struct LauncherResult: Identifiable {
    enum Action {
        case app(AppEntry)
        case file(FileEntry)
        case window(WindowAction, pid_t?)
        case url(URL)
        case copy(String)
    }
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let action: Action
    let score: Double
    var isCurrent = true
    var path: String? {
        switch action { case .app(let app): return app.path; case .file(let file): return file.path; default: return nil }
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [LauncherResult] = []
    @Published var selectedID: String?
    @Published var message: String?
    @Published private(set) var aiStatus = ""
    @Published private(set) var localSearchMS: Double = 0
    @Published private(set) var targetName = "Active Window"
    @Published private(set) var fileStatus = ""
    private var parsedFileQuery = FileSearchQuery(text: "")
    var isFileSearch: Bool { parsedFileQuery.isExplicitFileSearch }
    var emptyMessage: String {
        if isFileSearch { return fileStatus.isEmpty ? "No matching files" : fileStatus }
        return catalogue.scanning ? "Finding installed apps…" : "Search apps, files, or window commands"
    }
    let preferences: Preferences
    let catalogue: AppCatalogue
    let speech = SpeechService()
    let windows = WindowManager()
    var onClose: ((Bool) -> Void)?
    var focusSearch: (() -> Void)?
    private let files: FileSearching
    private let jev = JevService()
    private var fileResults: [FileEntry] = []
    private var previousFileResults: [FileEntry] = []
    private var work: Task<Void, Never>?
    private var aiWork: Task<Void, Never>?
    private var revision = UUID()
    private var visible = false
    private var acceptsSpeech = true
    private var startWork: Task<Void, Never>?
    private var manualSelection = false
    private var promotedID: String?
    private var semanticResult: LauncherResult?
    private var subscriptions = Set<AnyCancellable>()

    init(preferences: Preferences, catalogue: AppCatalogue, files: FileSearching? = nil) {
        self.preferences = preferences; self.catalogue = catalogue
        self.files = files ?? FileSearch()
        speech.onTranscript = { [weak self] text in
            guard let self, self.acceptsSpeech else { return }
            self.updateQuery(text, typed: false)
        }
        self.files.onStatus = { [weak self] status in
            guard let self, self.visible else { return }
            if self.fileStatus != status { self.fileStatus = status }
        }
        catalogue.$entries.sink { [weak self] _ in
            Task { @MainActor in guard let self, self.visible else { return }; self.rebuild() }
        }.store(in: &subscriptions)
    }
    func begin() {
        let targetApp = NSWorkspace.shared.frontmostApplication
        targetName = targetApp?.localizedName ?? "Active Window"
        windows.clearTarget()
        windows.gap = preferences.gap
        visible = true; acceptsSpeech = true; manualSelection = false; query = ""; message = nil
        parsedFileQuery = FileSearchQuery(text: ""); fileStatus = ""
        previousFileResults = []; fileResults = []; promotedID = nil; semanticResult = nil; revision = UUID()
        rebuild()
        startWork?.cancel()
        startWork = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.visible else { return }
            if let targetApp { self.windows.captureTarget(appPID: targetApp.processIdentifier) }
            if self.preferences.voiceEnabled && self.acceptsSpeech { self.speech.start() }
        }
    }
    func pauseListening() {
        acceptsSpeech = false; speech.stop()
        aiWork?.cancel()
        manualSelection = true
    }
    func toggleListening() {
        if speech.isListening || speech.isStarting { acceptsSpeech = false; speech.stop() }
        else { acceptsSpeech = true; speech.start() }
    }
    func enableVoice() async {
        await speech.requestPermissions()
        if visible && preferences.voiceEnabled { acceptsSpeech = true; speech.start() }
    }
    func end() {
        visible = false; revision = UUID()
        startWork?.cancel(); speech.stop(); work?.cancel(); aiWork?.cancel(); files.stop()
        aiStatus = ""
    }
    func updateQuery(_ text: String, typed: Bool) {
        guard visible else { return }
        if typed { acceptsSpeech = false; speech.stop() }
        guard text != query else { return }
        let wasFileSearch = isFileSearch
        parsedFileQuery = FileSearchQuery(text: text); fileStatus = ""
        if isFileSearch && wasFileSearch && parsedFileQuery.isValid {
            if !fileResults.isEmpty { previousFileResults = fileResults }
        } else { previousFileResults = [] }
        query = text; message = nil; manualSelection = false; fileResults = []; promotedID = nil; semanticResult = nil
        revision = UUID(); let current = revision
        work?.cancel(); aiWork?.cancel(); files.stop(); aiStatus = ""
        if isFileSearch { fileStatus = parsedFileQuery.validationError ?? "Searching files…" }
        rebuild()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        work = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.revision == current else { return }
            self.files.search(trimmed, folders: self.preferences.fileFolders) { [weak self] found in
                guard let self, self.visible, self.revision == current else { return }
                self.previousFileResults = []; self.fileResults = found; self.rebuild()
            }
        }
        if !isFileSearch && preferences.jevEnabled && trimmed.count >= 5 && trimmed.contains(" ") && (results.first?.score ?? 0) < 99 {
            aiWork = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled, let self, self.revision == current else { return }
                await self.interpret(trimmed, revision: current)
            }
        }
    }
    func rebuild() {
        let trace = PerformanceTrace.start("LocalResults")
        defer { PerformanceTrace.end("LocalResults", trace) }
        let start = CFAbsoluteTimeGetCurrent()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let runningApps = catalogue.runningApplications
        let running = Set(runningApps.compactMap(\.bundleURL).map(\.path))
        let aliasesByApp = Dictionary(grouping: preferences.aliases.keys, by: { preferences.aliases[$0]! })
        var rows: [LauncherResult] = []
        for app in catalogue.entries where !isFileSearch {
            let aliases = aliasesByApp[app.id] ?? []
            guard let score = q.isEmpty ? 0 : SearchRanking.score(query: q, title: app.name, aliases: aliases) else { continue }
            let frequent = min(Double(preferences.usage[app.id, default: 0]), 20) * 0.1
            let favourite = preferences.favourites.contains(app.id) ? (q.isEmpty ? 100.0 : 4.0) : 0
            let recent = q.isEmpty ? Double(20 - min(preferences.recentIDs.firstIndex(of: app.id) ?? 20, 20)) : 0
            rows.append(LauncherResult(id: app.id, title: app.name, detail: running.contains(app.path) ? "Running · " + app.path : app.path, symbol: "app", action: .app(app), score: score * 100 + frequent + favourite + recent))
        }
        let phrase = " " + q.lowercased().split(separator: " ").joined(separator: " ") + " "
        let namedTarget = runningApps
            .filter { $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName?.count ?? 0) > ($1.localizedName?.count ?? 0) }
            .first { app in
                guard let name = app.localizedName?.lowercased(), name.count > 1 else { return false }
                var names = [name]
                if name == "google chrome" { names.append("chrome") }
                if let path = app.bundleURL?.path {
                    names += (aliasesByApp["app:" + path] ?? []).map { $0.lowercased() }
                }
                return names.contains { phrase.contains(" " + $0 + " ") }
            }
        for action in WindowAction.allCases where !isFileSearch {
            guard let score = q.isEmpty ? -10 : SearchRanking.score(query: q, title: action.title, aliases: action.aliases) else { continue }
            rows.append(LauncherResult(id: "window:" + action.rawValue, title: action.title, detail: "Window · " + (namedTarget?.localizedName ?? targetName), symbol: action.symbol, action: .window(action, namedTarget?.processIdentifier), score: q.isEmpty ? -10 : score * 100))
        }
        let displayedFiles = fileResults.isEmpty ? previousFileResults : fileResults
        let filesAreCurrent = previousFileResults.isEmpty
        for (index, file) in displayedFiles.enumerated() {
            let nameScore = SearchRanking.score(query: parsedFileQuery.nameQuery, title: file.name) ?? 0.5
            let score = isFileSearch ? 200 - Double(index) : nameScore * 100 - 3 - Double(index) * 0.01
            rows.append(LauncherResult(id: file.id, title: file.name, detail: file.path,
                                       symbol: file.isDirectory ? "folder" : "doc.text", action: .file(file), score: score, isCurrent: filesAreCurrent))
        }
        if !isFileSearch, let answer = Calculator.evaluate(q) {
            rows.append(LauncherResult(id: "calculator", title: answer, detail: "Calculator · Return to copy", symbol: "equal.square", action: .copy(answer), score: 2000))
        }
        if !isFileSearch, let url = Self.directURL(q) {
            rows.append(LauncherResult(id: "url", title: "Open " + q, detail: url.absoluteString, symbol: "globe", action: .url(url), score: 1500))
        }
        if !q.isEmpty && !isFileSearch {
            var components = URLComponents(string: preferences.webEngine == "DuckDuckGo" ? "https://duckduckgo.com/" : "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: q)]
            if let url = components.url {
                rows.append(LauncherResult(id: "web", title: "Search " + preferences.webEngine, detail: q, symbol: "magnifyingglass", action: .url(url), score: -1000))
            }
        }
        if let semanticResult, !rows.contains(where: { $0.id == semanticResult.id }) { rows.append(semanticResult) }
        rows.sort {
            if $0.id == promotedID { return $1.id != promotedID }
            if $1.id == promotedID { return false }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        results = Array(rows.prefix(40))
        if !manualSelection || !results.contains(where: { $0.id == selectedID && $0.isCurrent }) { selectedID = results.first(where: \.isCurrent)?.id }
        localSearchMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
    private static func directURL(_ value: String) -> URL? {
        guard !value.contains(where: \.isWhitespace), !value.isEmpty else { return nil }
        let text = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, host.contains("."), host.rangeOfCharacter(from: .letters) != nil else { return nil }
        return url
    }
    private func interpret(_ text: String, revision current: UUID) async {
        do {
            guard let key = try KeychainStore.read(), !key.isEmpty else { aiStatus = "Add a TypeSafe key in Settings"; return }
            var candidates = results.filter { $0.id != "web" && $0.id != "calculator" }.map { JevCandidate(id: $0.id, title: $0.title, detail: $0.detail) }
            let included = Set(candidates.map(\.id))
            // All built-in window actions remain available even when phrasing has no literal match.
            candidates += WindowAction.allCases.filter { !included.contains("window:" + $0.rawValue) }.map {
                JevCandidate(id: "window:" + $0.rawValue, title: $0.title, detail: "Arrange the active window")
            }
            let existing = Set(candidates.map(\.id))
            candidates += catalogue.entries.filter { !existing.contains($0.id) }.prefix(max(0, 220 - candidates.count)).map {
                JevCandidate(id: $0.id, title: $0.name, detail: "Open installed application")
            }
            aiStatus = "Understanding…"
            let chosen = try await jev.choose(query: text, candidates: Array(candidates.prefix(240)), apiKey: key)
            guard !Task.isCancelled, visible, self.revision == current else { return }
            aiStatus = chosen == nil ? "No clear AI match" : "Jev matched"
            guard let chosen else { return }
            promotedID = chosen
            if !results.contains(where: { $0.id == chosen }) {
                if let app = catalogue.entries.first(where: { $0.id == chosen }) {
                    results.insert(LauncherResult(id: app.id, title: app.name, detail: app.path, symbol: "app", action: .app(app), score: 0), at: 0)
                } else if let action = WindowAction.allCases.first(where: { "window:" + $0.rawValue == chosen }) {
                    results.insert(LauncherResult(id: chosen, title: action.title, detail: "Window · " + targetName, symbol: action.symbol, action: .window(action, nil), score: 0), at: 0)
                }
            } else if let index = results.firstIndex(where: { $0.id == chosen }) {
                let row = results.remove(at: index); results.insert(row, at: 0)
            }
            semanticResult = results.first { $0.id == chosen }
            if !manualSelection { selectedID = results.first?.id }
        } catch {
            guard !Task.isCancelled, visible, revision == current else { return }
            aiStatus = "Jev unavailable · local results ready"
        }
    }
    func moveSelection(_ delta: Int) {
        let available = results.filter(\.isCurrent)
        guard !available.isEmpty else { return }
        let index = available.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = available[min(max(index + delta, 0), available.count - 1)].id
        manualSelection = true
    }
    func select(_ id: String) {
        guard results.contains(where: { $0.id == id && $0.isCurrent }) else { selectedID = nil; return }
        selectedID = id; manualSelection = true
    }
    var selected: LauncherResult? { results.first { $0.id == selectedID && $0.isCurrent } }
    func execute() {
        guard let result = selected else { message = "Choose an action first."; return }
        // Freeze the visible action before stopping speech or accepting an async response.
        revision = UUID(); work?.cancel(); aiWork?.cancel(); speech.stop(); files.stop()
        do {
            switch result.action {
            case .app(let app):
                guard FileManager.default.fileExists(atPath: app.path) else { throw LauncherError("This app moved or was removed. Refresh Apps in Settings.") }
                let url = URL(fileURLWithPath: app.path)
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
                    guard let error else { return }
                    Task { @MainActor in self?.showFailure(error.localizedDescription) }
                }
            case .file(let file):
                guard NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) else { throw LauncherError("The file could not be opened.") }
            case .window(let action, let pid): try windows.execute(action, appPID: pid)
            case .url(let url):
                guard NSWorkspace.shared.open(url) else { throw LauncherError("The URL could not be opened.") }
            case .copy(let text): copy(text)
            }
            preferences.record(result.id)
            switch result.action {
            case .copy: onClose?(true)
            case .window(_, let pid):
                onClose?(pid == nil)
                if let pid { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
            default: onClose?(false)
            }
        } catch { message = error.localizedDescription }
    }
    private func showFailure(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Could Not Open App"; alert.informativeText = text; alert.runModal()
    }
    func revealSelected() {
        guard let path = selected?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]); onClose?(false)
    }
    func copyPath() { if let path = selected?.path { copy(path); message = "Path copied" } }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
struct LauncherError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
