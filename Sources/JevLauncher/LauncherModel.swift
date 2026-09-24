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
        case clipboard(ClipboardItem)
        case command(SystemCommand)
        case custom(CustomCommand, input: String?)
        case stopProcess(ListeningPort)
        /// Open an app, then arrange its first window.
        case appThenWindow(AppEntry, WindowAction)
        case shortcut(String)
        case workflow(Workflow)
        case snippet(Snippet)
        case timer(TimerQuery)
        case cancelTimer(String)
        case menu(MenuCommand)
        /// Replace the query with this text, for a Jev pick such as Find Files.
        case route(String)
        /// A row from a source, with its own verbs.
        case thing(Thing)
    }
    let id: String
    let title: String
    /// Secondary text: the trailing accessory on single-line rows, the subtitle on two-line rows.
    var detail: String
    let symbol: String
    let action: Action
    var score: Double
    var isCurrent = true
    /// Overrides the kind-based group, for favourites and recent items.
    var section: LauncherGroup?
    var group: LauncherGroup {
        if let section { return section }
        switch action {
        case .app(let app): return app.launchURL == nil ? .applications : .commands
        case .file: return .files
        case .clipboard: return .clipboard
        case .window, .url, .copy, .command, .custom, .stopProcess, .appThenWindow, .shortcut, .workflow,
             .snippet, .timer, .cancelTimer, .menu, .route, .thing: return .commands
        }
    }
    /// Calculator answers and clipboard entries keep a second line; other rows are single-line.
    var isTwoLine: Bool {
        switch action {
        case .copy, .clipboard, .stopProcess: return true
        case .thing(let thing): return thing.twoLine
        default: return false
        }
    }
    var path: String? {
        switch action {
        case .app(let app): return app.path
        case .file(let file): return file.path
        case .thing(let thing): return thing.path
        default: return nil
        }
    }
    /// Disruptive actions run only after a second Return.
    var needsConfirmation: Bool {
        switch action {
        case .command(let command): return command.confirm
        case .thing(let thing): return thing.primary?.confirm ?? false
        default: return false
        }
    }
    /// Calculator answers, typed URLs, web searches, and clipboard text are not remembered for ranking.
    var learnsFromUse: Bool {
        switch action {
        case .copy, .clipboard, .stopProcess, .timer, .cancelTimer, .route, .menu, .thing: return false
        case .custom(_, let input): return input == nil
        case .url: return id.hasPrefix("quicklink:")
        default: return true
        }
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = ""
    /// Selectable results in display order: grouped, top hit first.
    @Published private(set) var results: [LauncherResult] = []
    /// Table rows: `results` with section labels between groups.
    @Published private(set) var rows: [LauncherRow] = []
    @Published var selectedID: String?
    @Published var message: String?
    @Published var aiStatus = ""
    /// A Jev failure worth showing, such as a missing key or a rate limit.
    @Published var aiError: String?
    /// Set when the user starts voice by hand and it cannot start.
    @Published private(set) var voiceError: String?
    @Published private(set) var localSearchMS: Double = 0
    @Published private(set) var targetName = "Active Window"
    @Published private(set) var fileStatus = ""
    private var parsedFileQuery = FileSearchQuery(text: "")
    var isFileSearch: Bool { parsedFileQuery.isExplicitFileSearch }
    /// Filter text when the query asks for clipboard history.
    private var clipboardFilter: String? { isFileSearch ? nil : ClipboardHistory.filter(for: query) }
    var isClipboardSearch: Bool { clipboardFilter != nil }
    /// Shown in place of rows when a typed query has none.
    var emptyMessage: String {
        if isFileSearch { return fileStatus.isEmpty || isSearchingFiles ? "No matching files" : fileStatus }
        if isClipboardSearch {
            return preferences.clipboardHistory ? "No clipboard entries yet" : "Clipboard history is off. Turn it on in Settings › General."
        }
        return "No results"
    }
    /// An explicit file search that has not finished.
    var isSearchingFiles: Bool { isFileSearch && fileStatus.hasPrefix("Searching") }
    /// Work the footer shows a spinner for, or nil.
    var loadingStatus: String? {
        if isSearchingFiles { return "Searching files…" }
        if aiStatus == Self.interpreting { return "Thinking…" }
        if lunaAnswer?.isLoading == true { return "Luna is writing…" }
        if catalogue.scanning && catalogue.entries.isEmpty && !isFileSearch && !isClipboardSearch { return "Finding apps…" }
        return nil
    }
    /// Empty query with nothing to suggest: the panel is only the search bar.
    var isCollapsed: Bool { query.isEmpty && rows.isEmpty }
    /// The single strip message: errors first, then permission and file-search hints.
    /// Voice setup lives in Settings › Input; the strip shows voice only after a real failure.
    var notice: Notice? {
        if let message { return Notice(symbol: "exclamationmark.triangle.fill", text: message, tone: .warning) }
        if let error = speech.errorMessage ?? voiceError { return Notice(symbol: "mic.slash", text: error, tone: .warning) }
        if case .window = selected?.action, !WindowManager.hasPermission {
            return Notice(symbol: "macwindow.badge.plus", text: "Window control needs Accessibility access.", tone: .info, action: .allowAccessibility)
        }
        if let pending = selected, pending.id == pendingConfirmID {
            if case .stopProcess = pending.action {
                return Notice(symbol: "exclamationmark.circle", text: "Press ⌫ again to " + confirmPhrase(pending) + ".", tone: .warning)
            }
            return Notice(symbol: "exclamationmark.circle", text: "Press Return again to " + confirmPhrase(pending) + ".", tone: .warning)
        }
        if let sourceNotice { return sourceNotice }
        if let portNotice { return Notice(symbol: "network", text: portNotice, tone: .info) }
        if let jevNotice { return Notice(symbol: "sparkles", text: jevNotice, tone: .info) }
        if let aiError { return Notice(symbol: "sparkles", text: aiError, tone: .info) }
        if isFileSearch && fileStatus.hasSuffix(FileSearch.narrowHint) && !results.isEmpty {
            return Notice(symbol: "info.circle", text: "Showing recent matches. Add a name or folder to narrow the search.", tone: .info)
        }
        return nil
    }
    /// What Return does with the selected result, for the footer.
    var primaryActionTitle: String? {
        if lunaAnswer != nil { return lunaPrimaryTitle }
        guard let selected else { return nil }
        switch selected.action {
        case .app(let app): return app.launchURL != nil ? "Open Settings" : "Open Application"
        case .file(let file): return file.isDirectory ? "Open Folder" : "Open File"
        case .window: return "Move Window"
        case .url:
            if selected.id == "web" { return "Search " + preferences.webEngine }
            if selected.id.hasPrefix("quicklink:"), let link = preferences.quicklinks.first(where: { "quicklink:" + $0.id == selected.id }) {
                return "Search " + link.name
            }
            return "Open URL"
        case .copy, .clipboard: return "Copy"
        case .command, .custom: return selected.id == pendingConfirmID ? "Confirm" : "Run Command"
        case .stopProcess(let listener): return "Open localhost:\(listener.port)"
        case .appThenWindow: return "Open and Arrange"
        case .shortcut: return "Run Shortcut"
        case .workflow: return "Run Workflow"
        case .snippet: return "Copy Snippet"
        case .timer: return "Start Timer"
        case .cancelTimer: return "Cancel Timer"
        case .menu: return "Choose Menu Item"
        case .route: return "Show"
        case .thing(let thing): return selected.id == pendingConfirmID ? "Confirm" : thing.primary?.title
        }
    }
    func perform(_ action: Notice.Action) {
        switch action {
        case .allowAccessibility: windows.requestPermission()
        case .grant(let access): grant(access)
        }
    }
    let preferences: Preferences
    let catalogue: AppCatalogue
    let speech = SpeechService()
    let windows = WindowManager()
    var onClose: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var focusSearch: (() -> Void)?
    /// Selected row frame in window coordinates, used to anchor the actions menu.
    var selectedRowRect: (() -> NSRect?)?
    let clipboard: ClipboardHistory
    private let files: FileSearching
    let jev: JevChoosing
    let usage: JevUsageLog?
    let timers = TimerCenter.shared
    /// Menu items of the app that was in front when the launcher opened.
    var menuCommands: [MenuCommand] = []
    /// The last calculator answers this session, newest first. Memory only.
    var answers: [String] = []
    /// The row Jev or local memory put first, and where the pick came from.
    var jevPick: (id: String, remembered: Bool)?
    /// The app whose window a layered Jev pick moves, when the request named one loosely.
    var jevWindowTarget: NSRunningApplication?
    /// Jev answers this session by request, so retyping a request costs nothing. Nil means no match.
    var replyCache: [String: (id: String?, at: Date)] = [:]
    let keys: JevKeyCache
    private var fileResults: [FileEntry] = []
    private var previousFileResults: [FileEntry] = []
    private var work: Task<Void, Never>?
    var aiWork: Task<Void, Never>?
    var revision = UUID()
    var visible = false
    var acceptsSpeech = true
    private var startWork: Task<Void, Never>?
    var manualSelection = false
    var promotedID: String?
    var semanticResult: LauncherResult?
    /// The port query in the search field, if any, and what lsof found for it.
    var portQuery: PortQuery?
    var listeners: [ListeningPort] = []
    /// CPU, memory, and command line for each listening process, refreshed while the list is open.
    var portDetails: [Int32: ProcessSnapshot] = [:]
    /// "Stopped node on :3000.", shown until the query changes.
    var stoppedNotice: String?
    var isLoadingPorts = false
    /// The source named in the search field, such as "scheduled tasks", and its rows.
    var sourceQuery: SourceQuery?
    var sourceRows: [LauncherResult] = []
    var sourceProblem: SourceProblem?
    /// A verb's result, such as "Turned off com.example.sync.", shown until the query or selection changes.
    var sourceNote: String?
    var isLoadingSource = false
    var sources: [SourceQuery.Kind: ThingSource] = [:]
    /// The page, files, or selected text in front when the launcher opened.
    var frontContext: FrontContext?
    /// The app in front when the launcher opened, and how far reading its context has gone.
    var contextApp: NSRunningApplication?
    enum ContextState { case none, withoutAsking, asked }
    var contextState = ContextState.none
    var contextRead: UUID?
    /// Changes each time the launcher opens, so late work from an earlier opening is dropped.
    var visibleSession = UUID()
    var sourceTask: Task<Void, Never>?
    /// Luna's answer in the panel, while it is written and after.
    @Published var lunaAnswer: LunaAnswer?
    var lunaWork: Task<Void, Never>?
    let luna: LunaWriting
    let lunaKeys: JevKeyCache
    let lunaLog: LunaActivityLog
    /// Scheduled Luna tasks. Made on first use; the app starts its clock at launch.
    lazy var lunaTasks = LunaTaskCenter(defaults: preferences.storage, send: { [weak self] request in
        guard let self else { throw CancellationError() }
        return try await self.sendLuna(request)
    }, allowed: { [weak self] in self?.allowedLunaContext ?? [] })
    /// Opens a task result window, set by the app.
    var openTaskRun: ((LunaTaskRun) -> Void)?
    /// Opens Settings › Luna, set by the app.
    var openLunaSettings: (() -> Void)?
    /// Opens the mail window, on a message when given; opens a new message to an address.
    var openMail: ((Int64?) -> Void)?
    var composeMail: ((String) -> Void)?
    /// The row that is waiting for a second Return.
    @Published var pendingConfirmID: String?
    private var subscriptions = Set<AnyCancellable>()

    init(preferences: Preferences, catalogue: AppCatalogue, files: FileSearching? = nil,
         jev: JevChoosing = JevService(), keys: JevKeyCache? = nil, clipboard: ClipboardHistory? = nil, usage: JevUsageLog? = nil,
         luna: LunaWriting = LunaService(), lunaKeys: JevKeyCache? = nil, lunaLog: LunaActivityLog? = nil) {
        self.preferences = preferences; self.catalogue = catalogue
        self.luna = luna; self.lunaKeys = lunaKeys ?? .luna; self.lunaLog = lunaLog ?? .shared
        self.files = files ?? FileSearch()
        self.jev = jev
        self.usage = usage
        self.keys = keys ?? .shared
        self.clipboard = clipboard ?? ClipboardHistory()
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
        preferences.$clipboardHistory.sink { [weak self] enabled in self?.clipboard.setEnabled(enabled) }.store(in: &subscriptions)
    }
    func begin() {
        let targetApp = NSWorkspace.shared.frontmostApplication
        targetName = targetApp?.localizedName ?? "Active Window"
        windows.clearTarget()
        windows.gap = preferences.gap
        visible = true; acceptsSpeech = true; manualSelection = false; query = ""; message = nil; voiceError = nil
        parsedFileQuery = FileSearchQuery(text: ""); fileStatus = ""
        previousFileResults = []; fileResults = []; promotedID = nil; semanticResult = nil; revision = UUID()
        portQuery = nil; listeners = []; portDetails = [:]; stoppedNotice = nil; isLoadingPorts = false; pendingConfirmID = nil
        sourceQuery = nil; sourceRows = []; sourceProblem = nil; sourceNote = nil; isLoadingSource = false
        jevPick = nil; menuCommands = []; frontContext = nil; visibleSession = UUID(); dismissLuna()
        contextApp = targetApp; contextState = .none
        rebuild()
        ShortcutsCatalogue.shared.refreshIfStale()
        startWork?.cancel()
        startWork = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.visible else { return }
            if let targetApp {
                self.windows.captureTarget(appPID: targetApp.processIdentifier)
                self.loadMenuCommands(for: targetApp)
            }
            if self.preferences.voiceEnabled && self.acceptsSpeech && self.speech.permissionsGranted { self.speech.start() }
        }
    }
    func pauseListening() {
        acceptsSpeech = false; speech.stop()
        aiWork?.cancel()
        manualSelection = true
    }
    /// The mic button. A start that fails at once shows its reason in the strip.
    func toggleListening() {
        voiceError = nil
        if speech.isListening || speech.isStarting { acceptsSpeech = false; speech.stop(); return }
        acceptsSpeech = true; speech.start()
        if !speech.isStarting && !speech.isListening { voiceError = speech.status }
    }
    func end() {
        visible = false; revision = UUID(); sourceTask?.cancel(); dismissLuna()
        startWork?.cancel(); speech.stop(); work?.cancel(); aiWork?.cancel(); files.stop()
        aiStatus = ""; aiError = nil
    }
    func updateQuery(_ text: String, typed: Bool) {
        guard visible else { return }
        if typed { acceptsSpeech = false; speech.stop() }
        guard text != query else { return }
        dismissLuna()
        let wasFileSearch = isFileSearch
        parsedFileQuery = FileSearchQuery(text: text); fileStatus = ""
        if isFileSearch && wasFileSearch && parsedFileQuery.isValid {
            if !fileResults.isEmpty { previousFileResults = fileResults }
        } else { previousFileResults = [] }
        query = text; message = nil; manualSelection = false; fileResults = []; promotedID = nil; semanticResult = nil
        pendingConfirmID = nil; portQuery = PortQuery.parse(text); listeners = []; portDetails = [:]; stoppedNotice = nil; jevPick = nil; jevWindowTarget = nil
        let previousKind = sourceQuery?.kind
        sourceQuery = isFileSearch || portQuery != nil ? nil : SourceQuery.parse(text)
        if sourceQuery.map({ source($0.kind) == nil }) ?? false { sourceQuery = nil }
        // The same source keeps its rows on screen, not runnable, until the new filter loads.
        sourceRows = sourceQuery?.kind == previousKind ? sourceRows.map { var row = $0; row.isCurrent = false; return row } : []
        sourceProblem = nil; sourceNote = nil; sourceTask?.cancel()
        revision = UUID(); let current = revision
        work?.cancel(); aiWork?.cancel(); files.stop(); aiStatus = ""; aiError = nil
        if typed { voiceError = nil }
        loadContextIfNeeded(text.trimmingCharacters(in: .whitespaces))
        if isFileSearch { fileStatus = parsedFileQuery.validationError ?? "Searching files…" }
        rebuild()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clipboard filters and keyword searches with text stay local and skip file search.
        guard !trimmed.isEmpty, !isClipboardSearch, Quicklink.match(trimmed, in: preferences.quicklinks)?.query.isEmpty ?? true else { return }
        if let portQuery { loadPorts(portQuery, revision: current, promoteFirst: false) }
        if sourceQuery != nil { loadSource(revision: current, delay: 120_000_000) }
        if portQuery == nil && (isFileSearch || trimmed.count >= 3) {
            work = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self, self.revision == current else { return }
                self.files.search(trimmed, folders: self.preferences.fileFolders) { [weak self] found in
                    guard let self, self.visible, self.revision == current else { return }
                    self.previousFileResults = []; self.fileResults = found; self.rebuild()
                }
            }
        }
        scheduleJev(trimmed, revision: current)
    }
    func rebuild() {
        let trace = PerformanceTrace.start("LocalResults")
        defer { PerformanceTrace.end("LocalResults", trace) }
        let start = CFAbsoluteTimeGetCurrent()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let filter = clipboardFilter {
            let rows = clipboard.matches(filter).enumerated().map { index, item in
                LauncherResult(id: "clip:" + item.id.uuidString, title: Self.clipboardTitle(item.text),
                               detail: Self.clipboardDetail(item),
                               symbol: "doc.on.clipboard", action: .clipboard(item), score: 1000 - Double(index))
            }
            publish(rows, start: start)
            return
        }
        if let rows = exclusiveRows(q) {
            publish(rows, start: start)
            return
        }
        let running = Set(catalogue.runningApplications.compactMap(\.bundleURL).map(\.path))
        // An empty query is the search bar alone: no favourites or recent items.
        if q.isEmpty && !isFileSearch {
            publish([], start: start)
            return
        }
        let aliasesByApp = self.aliasesByApp
        var rows: [LauncherResult] = []
        for app in catalogue.entries where !isFileSearch {
            let aliases = aliasesByApp[app.id] ?? []
            guard let score = SearchRanking.score(query: q, title: app.name, aliases: aliases) else { continue }
            let favourite = preferences.favourites.contains(app.id) ? 4.0 : 0
            rows.append(Self.appRow(app, running: running.contains(app.path), score: score * 100 + favourite))
        }
        let namedTarget = namedTarget(in: q)
        for action in WindowAction.allCases where !isFileSearch {
            guard let score = SearchRanking.score(query: q, title: action.title, aliases: action.aliases) else { continue }
            rows.append(windowRow(action, target: namedTarget, score: score * 100))
        }
        let displayedFiles = fileResults.isEmpty ? previousFileResults : fileResults
        let filesAreCurrent = previousFileResults.isEmpty
        for (index, file) in displayedFiles.enumerated() {
            let nameScore = SearchRanking.score(query: parsedFileQuery.nameQuery, title: file.name) ?? 0.5
            let score = isFileSearch ? 200 - Double(index) : nameScore * 100 - 3 - Double(index) * 0.01
            rows.append(Self.fileRow(file, score: score, isCurrent: filesAreCurrent))
        }
        if !isFileSearch {
            rows += quicklinkRows(q) + commandRows(q) + portRows() + extraRows(q) + sourceRows
            rows += compoundRows(q, among: rows)
        }
        let answer = isFileSearch ? nil : (Calculator.evaluate(q) ?? QueryText.substitutingAnswer(q, last: answers.first).flatMap(Calculator.evaluate))
        // A finished sum or conversion is the answer. Beside it, keep only whole-name and
        // prefix matches (90 and up), so "12 * (8 + 2)" does not list "Left Two Thirds"
        // for its "2". File rows already had to match every word.
        if answer != nil && q.contains(where: \.isNumber) {
            rows.removeAll { row in
                if case .file = row.action { return false }
                return row.score < 90
            }
        }
        // Learned use reorders close matches. The boost stays under 10 points, the gap
        // between an exact match (100) and the best non-exact match (90).
        let now = Date(), frecency = preferences.frecency
        rows = rows.map { row in
            guard row.learnsFromUse else { return row }
            let boost = frecency.boost(for: row.id, query: q, now: now) * Self.maxBoost
            return boost > 0 ? row.adding(boost) : row
        }
        if let answer {
            let kind = q.rangeOfCharacter(from: .letters) == nil ? "Calculator" : "Conversion"
            rows.append(LauncherResult(id: "calculator", title: answer, detail: kind, symbol: "equal.square", action: .copy(answer), score: 2000))
        }
        if !isFileSearch, let url = Self.directURL(q) {
            rows.append(LauncherResult(id: "url", title: "Open " + q, detail: "", symbol: "globe", action: .url(url), score: 1500))
        }
        if !isFileSearch {
            var components = URLComponents(string: preferences.webEngine == "DuckDuckGo" ? "https://duckduckgo.com/" : "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: q)]
            if let url = components.url {
                rows.append(LauncherResult(id: "web", title: "Search " + preferences.webEngine, detail: Self.hostDetail(url), symbol: "magnifyingglass", action: .url(url), score: -1000))
            }
        }
        // A pick can replace a plain row with a richer one, such as a site search with the request's words.
        if let semanticResult {
            rows.removeAll { $0.id == semanticResult.id }
            rows.append(semanticResult)
        }
        publish(rows, start: start)
    }
    static let maxBoost = 9.0
    static let interpreting = "Understanding…"
    private func publish(_ unsorted: [LauncherResult], start: CFAbsoluteTime) {
        var unsorted = unsorted
        if let jevPick, let index = unsorted.firstIndex(where: { $0.id == jevPick.id }) {
            let badge = jevPick.remembered ? "Remembered" : "Jev"
            unsorted[index].detail = unsorted[index].detail.isEmpty ? badge : badge + " · " + unsorted[index].detail
        }
        let ranked = unsorted.sorted {
            if $0.id == promotedID { return $1.id != promotedID }
            if $1.id == promotedID { return false }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let mixed = !isFileSearch && !isClipboardSearch && !query.isEmpty
        var groups = LauncherSections.group(Array(ranked.prefix(40)), fileLimit: mixed ? LauncherSections.mixedFileLimit : nil)
        // A long clipboard or file list stays one group; the cap bounds the table.
        groups = groups.filter { !$0.results.isEmpty }
        rows = LauncherSections.rows(groups)
        results = groups.flatMap(\.results)
        if !manualSelection || !results.contains(where: { $0.id == selectedID && $0.isCurrent }) { selectedID = results.first(where: \.isCurrent)?.id }
        localSearchMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
    var aliasesByApp: [String: [String]] {
        Dictionary(grouping: preferences.aliases.keys, by: { preferences.aliases[$0]! })
    }
    /// Trailing accessory for an app: "Running" only when it runs; "Settings" for a System Settings pane.
    static func appDetail(_ app: AppEntry, running: Bool) -> String {
        app.launchURL != nil ? "Settings" : running ? "Running" : ""
    }
    /// The containing folder, short: "~/Downloads" when it has two components
    /// or fewer, otherwise "…/" and the last two. Copy Path, Reveal, and Quick
    /// Look still use the full path.
    nonisolated static func folderDetail(_ path: String, home: String = displayHome) -> String {
        var folder = (path as NSString).deletingLastPathComponent
        let homePrefix = home.hasSuffix("/") ? String(home.dropLast()) : home
        if folder == homePrefix { return "~" }
        if folder.hasPrefix(homePrefix + "/") { folder = "~" + folder.dropFirst(homePrefix.count) }
        let parts = folder.split(separator: "/").filter { $0 != "~" }
        guard parts.count > 2 else { return folder }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
    /// The folder shown as "~". Demo captures point it at their sample files.
    nonisolated(unsafe) static var displayHome = NSHomeDirectory()
    /// Replaces the frontmost app's name on window rows, so demo captures name a neutral app.
    func overrideTargetName(_ name: String) { targetName = name }
    /// A URL's host without "www.", such as "github.com".
    nonisolated static func hostDetail(_ url: URL) -> String {
        let host = url.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    static func appRow(_ app: AppEntry, running: Bool, score: Double) -> LauncherResult {
        LauncherResult(id: app.id, title: app.name, detail: appDetail(app, running: running),
                       symbol: app.launchURL != nil ? "gearshape" : "app", action: .app(app), score: score)
    }
    static func fileRow(_ file: FileEntry, score: Double, isCurrent: Bool) -> LauncherResult {
        LauncherResult(id: file.id, title: file.name, detail: folderDetail(file.path),
                       symbol: file.isDirectory ? "folder" : "doc.text", action: .file(file), score: score, isCurrent: isCurrent)
    }
    /// A window action row. The accessory names the app it will move.
    func windowRow(_ action: WindowAction, target: NSRunningApplication?, score: Double) -> LauncherResult {
        LauncherResult(id: "window:" + action.rawValue, title: action.title, detail: target?.localizedName ?? targetName,
                       symbol: action.symbol, action: .window(action, target?.processIdentifier), score: score)
    }
    private static func clipboardDetail(_ item: ClipboardItem) -> String {
        let lines = item.text.split(whereSeparator: \.isNewline).count
        let age = "Copied " + item.copiedAt.formatted(.relative(presentation: .named))
        return lines > 1 ? age + " · \(lines) lines" : age
    }
    private static func clipboardTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }
    private func quicklinkRows(_ q: String) -> [LauncherResult] {
        var rows: [LauncherResult] = []
        let matched = Quicklink.match(q, in: preferences.quicklinks)
        if let (link, text) = matched, let url = link.url(for: text) {
            rows.append(text.isEmpty
                ? LauncherResult(id: "quicklink:" + link.id, title: "Search " + link.name, detail: Self.hostDetail(url), symbol: "link", action: .url(url), score: 950)
                : LauncherResult(id: "quicklink:" + link.id, title: "Search \(link.name) for \(text)", detail: Self.hostDetail(url), symbol: "link", action: .url(url), score: 1800))
        }
        for link in preferences.quicklinks where link.id != matched?.link.id {
            guard let score = SearchRanking.score(query: q, title: link.name, aliases: [link.keyword]), let url = link.url(for: "") else { continue }
            rows.append(LauncherResult(id: "quicklink:" + link.id, title: "Search " + link.name, detail: Self.hostDetail(url), symbol: "link", action: .url(url), score: score * 100))
        }
        return rows
    }
    /// A running app named in the query, such as "Safari" in "safari left half".
    func namedTarget(in query: String) -> NSRunningApplication? {
        let apps = catalogue.runningApplications.filter { $0.processIdentifier != getpid() }
        let aliasesByApp = self.aliasesByApp
        let names = apps.map { app in
            (name: app.localizedName ?? "", aliases: app.bundleURL.map { aliasesByApp["app:" + $0.path] ?? [] } ?? [])
        }
        return Self.namedTargetIndex(in: query, apps: names).map { apps[$0] }
    }
    private nonisolated static let vendorPrefixes = ["google ", "microsoft ", "adobe ", "apple ", "jetbrains "]
    /// Index of the longest-named app whose name, short name, or alias appears as whole words in `query`.
    nonisolated static func namedTargetIndex(in query: String, apps: [(name: String, aliases: [String])]) -> Int? {
        let phrase = " " + query.lowercased().split(separator: " ").joined(separator: " ") + " "
        return apps.indices
            .sorted { apps[$0].name.count > apps[$1].name.count }
            .first { index in
                let name = apps[index].name.lowercased()
                guard name.count > 1 else { return false }
                var names = [name] + apps[index].aliases.map { $0.lowercased() }
                if name == "google chrome" { names.append("chrome") }
                if let vendor = vendorPrefixes.first(where: { name.hasPrefix($0) }) { names.append(String(name.dropFirst(vendor.count))) }
                return names.contains { $0.count > 1 && phrase.contains(" " + $0 + " ") }
            }
    }
    private static func directURL(_ value: String) -> URL? {
        guard !value.contains(where: \.isWhitespace), !value.isEmpty else { return nil }
        let text = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, host.contains("."), host.rangeOfCharacter(from: .letters) != nil else { return nil }
        return url
    }
    func moveSelection(_ delta: Int) {
        let available = results.filter(\.isCurrent)
        guard !available.isEmpty else { return }
        let index = available.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = available[min(max(index + delta, 0), available.count - 1)].id
        manualSelection = true; pendingConfirmID = nil; stoppedNotice = nil; sourceNote = nil
    }
    func select(_ id: String) {
        guard results.contains(where: { $0.id == id && $0.isCurrent }) else { selectedID = nil; return }
        if selectedID != id { pendingConfirmID = nil }
        selectedID = id; manualSelection = true
    }
    var selected: LauncherResult? { results.first { $0.id == selectedID && $0.isCurrent } }
    func execute(paste: Bool = false) {
        if lunaAnswer != nil { finishLunaAnswer(paste: paste); return }
        guard let result = selected else { message = "Choose an action first."; return }
        if result.needsConfirmation && pendingConfirmID != result.id { pendingConfirmID = result.id; return }
        pendingConfirmID = nil
        // Freeze the visible action before stopping speech or accepting an async response.
        revision = UUID(); work?.cancel(); aiWork?.cancel(); speech.stop(); files.stop()
        do {
            switch result.action {
            case .app(let app) where app.launchURL != nil:
                guard let url = app.launchURL.flatMap(URL.init(string:)), Frontmost.open(url) else { throw LauncherError("That settings pane could not be opened.") }
            case .app(let app):
                guard FileManager.default.fileExists(atPath: app.path) else { throw LauncherError("This app moved or was removed. Refresh apps in Settings › Search › Advanced.") }
                let url = URL(fileURLWithPath: app.path)
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                Frontmost.openApplication(at: url, configuration: config) { [weak self] _, error in
                    guard let error else { return }
                    Task { @MainActor in self?.showFailure(error.localizedDescription) }
                }
            case .file(let file):
                guard Frontmost.open(URL(fileURLWithPath: file.path)) else { throw LauncherError("The file could not be opened.") }
            case .window(let action, let pid): try windows.execute(action, appPID: pid)
            case .url(let url):
                guard Frontmost.open(url) else { throw LauncherError("The URL could not be opened.") }
            case .copy(let text): copy(text)
            case .clipboard(let item): clipboard.restore(item)
            case .command(let command): run(command)
            case .custom(let command, let input): run(command, input: input)
            case .stopProcess(let listener):
                // Return opens the server. ⌫ stops it, without closing the launcher.
                guard let url = URL(string: "http://localhost:\(listener.port)"), Frontmost.open(url) else { throw LauncherError("The browser could not open port \(listener.port).") }
            case .appThenWindow(let app, let action): openThenArrange(app, action)
            case .shortcut(let name): runShortcut(name)
            case .workflow(let workflow): run(workflow)
            case .snippet(let snippet): copy(snippet.expanded(clipboard: NSPasteboard.general.string(forType: .string)))
            case .timer(let timer): start(timer)
            case .cancelTimer(let id): timers.cancel(id)
            case .menu(let command): pressLater(command)
            case .route(let text):
                updateQuery(text, typed: false)
                return
            case .thing(let thing):
                guard let verb = thing.primary else { return }
                run(verb, on: result)
                return
            }
            if result.id == "calculator", case .copy(let text) = result.action { answers = [text] + answers.filter { $0 != text }.prefix(9) }
            learnFromExecution(result)
            if result.learnsFromUse { preferences.record(result.id, query: query) }
            switch result.action {
            case .copy, .clipboard, .snippet:
                onClose?(true)
                if paste { Paster.pasteSoon() }
            case .command, .custom, .timer, .cancelTimer, .shortcut, .workflow: onClose?(true)
            case .menu: onClose?(true)
            case .window(_, let pid):
                onClose?(pid == nil)
                if let pid { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
            default: onClose?(false)
            }
        } catch { message = error.localizedDescription }
    }
    func showFailure(_ text: String) {
        if let onFailure { onFailure(text) } else { message = text }
    }
    func revealSelected() {
        guard let path = selected?.path else { return }
        Frontmost.reveal([URL(fileURLWithPath: path)]); onClose?(false)
    }
    func copyPath() { if let path = selected?.path { copy(path); message = "Path copied" } }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
extension LauncherResult {
    func adding(_ boost: Double) -> LauncherResult {
        var row = self; row.score += boost; return row
    }
}
struct LauncherError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
