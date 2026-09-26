import AppKit
import Combine
import LauncherCore
import ServiceManagement

@MainActor
final class Preferences: ObservableObject {
    @Published var hotkey: Hotkey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: "voiceEnabled") } }
    @Published var jevEnabled: Bool { didSet { defaults.set(jevEnabled, forKey: "jevEnabled") } }
    /// Jev also names the kind of request, and chooses again within that kind when the two differ.
    @Published var jevLayered: Bool { didSet { defaults.set(jevLayered, forKey: "jevLayered") } }
    /// Quill writes and reads text when a request needs it. Off until the user turns it on.
    @Published var quillEnabled: Bool { didSet { defaults.set(quillEnabled, forKey: QuillStorageKeys.enabled) } }
    @Published var quillEffort: ReasoningEffort { didSet { defaults.set(quillEffort.rawValue, forKey: QuillStorageKeys.effort) } }
    /// Fast asks OpenRouter for the priority service tier. Off by default.
    @Published var quillFast: Bool { didSet { defaults.set(quillFast, forKey: QuillStorageKeys.fast) } }
    /// The OpenRouter model ID Quill sends.
    @Published var quillModel: String { didSet { defaults.set(quillModel, forKey: QuillStorageKeys.model) } }
    /// Each kind of context Quill may receive. What the user types is always allowed once Quill is on.
    @Published var quillSendsSelection: Bool { didSet { defaults.set(quillSendsSelection, forKey: QuillStorageKeys.sendsSelection) } }
    @Published var quillSendsMail: Bool { didSet { defaults.set(quillSendsMail, forKey: QuillStorageKeys.sendsMail) } }
    @Published var quillSendsCalendar: Bool { didSet { defaults.set(quillSendsCalendar, forKey: QuillStorageKeys.sendsCalendar) } }
    @Published var quillSendsUnreadMail: Bool { didSet { defaults.set(quillSendsUnreadMail, forKey: QuillStorageKeys.sendsUnreadMail) } }
    /// Quill cleans dictation transcripts. Off until the user turns it on.
    @Published var quillSendsDictation: Bool { didSet { defaults.set(quillSendsDictation, forKey: QuillStorageKeys.sendsDictation) } }
    /// Hold Right Command to dictate into the front app. Off until the user turns it on.
    @Published var dictationEnabled: Bool { didSet { defaults.set(dictationEnabled, forKey: "dictationEnabled") } }
    @Published var dictationRetention: DictationRetention { didSet { defaults.set(dictationRetention.rawValue, forKey: "dictationRetention") } }
    @Published var edgeSnapping: Bool { didSet { defaults.set(edgeSnapping, forKey: "edgeSnapping") } }
    @Published var windowShortcuts: Bool { didSet { defaults.set(windowShortcuts, forKey: "windowShortcuts") } }
    @Published var gap: Double { didSet { defaults.set(gap, forKey: "gap") } }
    /// Caps Lock becomes Hyper: held, it runs the keys in `hyperBindings`. Off by default.
    @Published var hyperKeyEnabled: Bool { didSet { defaults.set(hyperKeyEnabled, forKey: "hyperKeyEnabled") } }
    @Published var hyperBindings: [HyperBinding] { didSet { save(hyperBindings, "hyperBindings") } }
    @Published var webEngine: String { didSet { defaults.set(webEngine, forKey: "webEngine") } }
    @Published var appFolders: [String] { didSet { defaults.set(appFolders, forKey: "appFolders") } }
    @Published var fileFolders: [String] { didSet { defaults.set(fileFolders, forKey: "fileFolders") } }
    @Published var favourites: [String] { didSet { defaults.set(favourites, forKey: "favourites") } }
    /// Apps left out of search and Jev, such as an old copy of an app you no longer use.
    @Published var hiddenApps: [String] { didSet { defaults.set(hiddenApps, forKey: "hiddenApps") } }
    /// Cleanup items you chose never to be offered again, by key, such as "server:node:3000".
    @Published var cleanupIgnored: [String] { didSet { defaults.set(cleanupIgnored, forKey: "cleanupIgnored") } }
    @Published var aliases: [String: String] { didSet { defaults.set(aliases, forKey: "aliases") } }
    @Published var quicklinks: [Quicklink] { didSet { defaults.set(try? JSONEncoder().encode(quicklinks), forKey: "quicklinks") } }
    /// Commands the user writes. Only their names go to Jev.
    @Published var customCommands: [CustomCommand] { didSet { save(customCommands, "customCommands") } }
    @Published var workflows: [Workflow] { didSet { save(workflows, "workflows") } }
    @Published var snippets: [Snippet] { didSet { save(snippets, "snippets") } }
    /// Requests already resolved on this Mac, so they skip Jev next time.
    @Published private(set) var learned: LearnedIntents
    @Published var clipboardHistory: Bool { didSet { defaults.set(clipboardHistory, forKey: "clipboardHistory") } }
    @Published var checksForUpdates: Bool { didSet { defaults.set(checksForUpdates, forKey: "checksForUpdates") } }
    /// Set once the welcome window has been shown, so it opens by itself only on a new install.
    @Published var welcomeShown: Bool { didSet { defaults.set(welcomeShown, forKey: "welcomeShown") } }
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }
    // Automations: app-side choices. Runner-shared values live in `AutomationSettings`.
    /// Notch alerts for automations at all.
    @Published var automationAlerts: Bool { didSet { defaults.set(automationAlerts, forKey: "automationAlerts") } }
    @Published var automationAlertFailures: Bool { didSet { defaults.set(automationAlertFailures, forKey: "automationAlertFailures") } }
    @Published var automationQuietHours: Bool { didSet { defaults.set(automationQuietHours, forKey: "automationQuietHours") } }
    /// Minutes after local midnight.
    @Published var automationQuietStart: Int { didSet { defaults.set(automationQuietStart, forKey: "automationQuietStart") } }
    @Published var automationQuietEnd: Int { didSet { defaults.set(automationQuietEnd, forKey: "automationQuietEnd") } }
    @Published var automationHideNames: Bool { didSet { defaults.set(automationHideNames, forKey: "automationHideNames") } }
    @Published var automationAlertSeconds: Double { didSet { defaults.set(automationAlertSeconds, forKey: "automationAlertSeconds") } }
    @Published var automationRunner: AgentRunner { didSet { defaults.set(automationRunner.rawValue, forKey: "automationRunner") } }
    @Published var automationCodexModel: String { didSet { defaults.set(automationCodexModel, forKey: "automationCodexModel") } }
    @Published var automationClaudeModel: String { didSet { defaults.set(automationClaudeModel, forKey: "automationClaudeModel") } }
    @Published var automationEffort: ReasoningEffort { didSet { defaults.set(automationEffort.rawValue, forKey: "automationEffort") } }
    @Published var automationFast: Bool { didSet { defaults.set(automationFast, forKey: "automationFast") } }
    @Published var automationAccess: AgentAccess { didSet { defaults.set(automationAccess.rawValue, forKey: "automationAccess") } }
    /// Minutes before a new automation's run is stopped.
    @Published var automationTimeoutMinutes: Int { didSet { defaults.set(automationTimeoutMinutes, forKey: "automationTimeoutMinutes") } }
    static let automationTimeoutChoices = [5, 10, 20, 30, 60]
    @Published var showCodexAutomations: Bool { didSet { defaults.set(showCodexAutomations, forKey: "showCodexAutomations") } }
    @Published private(set) var recentIDs: [String]
    @Published private(set) var frecency: Frecency
    private let defaults: UserDefaults
    /// The store these preferences use, for data kept beside them such as scheduled tasks.
    var storage: UserDefaults { defaults }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        // Any key an earlier version always wrote. Read before this init saves anything.
        let existingInstall = ["frecency", "usage", "hotkey", "recentIDs"].contains { d.object(forKey: $0) != nil }
        // New installs start on Option–Space, the shortcut the website shows. An earlier install
        // that never chose one was on Control–Shift–Space and keeps it.
        hotkey = (d.object(forKey: "hotkey") as? Int).flatMap(Hotkey.init(rawValue:))
            ?? (existingInstall ? .controlShiftSpace : .optionSpace)
        // New installs start with the microphone off; the welcome window offers it. Earlier installs keep listening.
        voiceEnabled = d.object(forKey: "voiceEnabled") as? Bool ?? existingInstall
        checksForUpdates = d.object(forKey: "checksForUpdates") as? Bool ?? true
        welcomeShown = d.object(forKey: "welcomeShown") as? Bool ?? existingInstall
        jevEnabled = d.bool(forKey: "jevEnabled")
        jevLayered = d.object(forKey: "jevLayered") as? Bool ?? true
        quillEnabled = d.bool(forKey: QuillStorageKeys.enabled)
        quillEffort = d.string(forKey: QuillStorageKeys.effort).flatMap(ReasoningEffort.init(storedQuillValue:))
            .flatMap { ReasoningEffort.quillChoices.contains($0) ? $0 : nil } ?? .low
        quillFast = d.bool(forKey: QuillStorageKeys.fast)
        quillModel = d.string(forKey: QuillStorageKeys.model).flatMap { id in QuillModel.catalog.contains { $0.id == id } ? id : nil }
            ?? QuillModel.defaultID
        quillSendsSelection = d.bool(forKey: QuillStorageKeys.sendsSelection)
        quillSendsMail = d.bool(forKey: QuillStorageKeys.sendsMail)
        quillSendsCalendar = d.bool(forKey: QuillStorageKeys.sendsCalendar)
        quillSendsUnreadMail = d.bool(forKey: QuillStorageKeys.sendsUnreadMail)
        quillSendsDictation = d.bool(forKey: QuillStorageKeys.sendsDictation)
        dictationEnabled = d.bool(forKey: "dictationEnabled")
        dictationRetention = d.string(forKey: "dictationRetention").flatMap(DictationRetention.init(rawValue:)) ?? .days30
        edgeSnapping = d.bool(forKey: "edgeSnapping")
        windowShortcuts = d.bool(forKey: "windowShortcuts")
        gap = d.object(forKey: "gap") as? Double ?? 8
        hyperKeyEnabled = d.bool(forKey: "hyperKeyEnabled")
        hyperBindings = Self.load(d, "hyperBindings") ?? HyperLayer.defaults
        webEngine = d.string(forKey: "webEngine") ?? "Google"
        appFolders = d.stringArray(forKey: "appFolders") ?? []
        fileFolders = d.stringArray(forKey: "fileFolders") ?? [NSHomeDirectory()]
        favourites = d.stringArray(forKey: "favourites") ?? []
        hiddenApps = d.stringArray(forKey: "hiddenApps") ?? []
        cleanupIgnored = d.stringArray(forKey: "cleanupIgnored") ?? []
        aliases = d.dictionary(forKey: "aliases") as? [String: String] ?? [:]
        quicklinks = d.data(forKey: "quicklinks").flatMap { try? JSONDecoder().decode([Quicklink].self, from: $0) } ?? Quicklink.defaults
        customCommands = Self.load(d, "customCommands") ?? []
        workflows = Self.load(d, "workflows") ?? []
        snippets = Self.load(d, "snippets") ?? []
        learned = Self.load(d, "learnedIntents") ?? LearnedIntents()
        clipboardHistory = d.object(forKey: "clipboardHistory") as? Bool ?? true
        automationAlerts = d.object(forKey: "automationAlerts") as? Bool ?? true
        automationAlertFailures = d.object(forKey: "automationAlertFailures") as? Bool ?? true
        automationQuietHours = d.bool(forKey: "automationQuietHours")
        automationQuietStart = d.object(forKey: "automationQuietStart") as? Int ?? 22 * 60
        automationQuietEnd = d.object(forKey: "automationQuietEnd") as? Int ?? 7 * 60
        automationHideNames = d.bool(forKey: "automationHideNames")
        automationAlertSeconds = min(max(d.object(forKey: "automationAlertSeconds") as? Double ?? 6, 4), 12)
        automationRunner = d.string(forKey: "automationRunner").flatMap(AgentRunner.init(rawValue:)) ?? .codex
        automationCodexModel = d.string(forKey: "automationCodexModel") ?? ""
        automationClaudeModel = d.string(forKey: "automationClaudeModel") ?? ""
        automationEffort = d.string(forKey: "automationEffort").flatMap(ReasoningEffort.init(rawValue:)) ?? .medium
        automationFast = d.bool(forKey: "automationFast")
        automationAccess = d.string(forKey: "automationAccess").flatMap(AgentAccess.init(rawValue:)) ?? .readOnly
        showCodexAutomations = d.object(forKey: "showCodexAutomations") as? Bool ?? true
        automationTimeoutMinutes = (d.object(forKey: "automationTimeoutMinutes") as? Int).flatMap { Self.automationTimeoutChoices.contains($0) ? $0 : nil } ?? 20
        recentIDs = d.stringArray(forKey: "recentIDs") ?? []
        if let data = d.data(forKey: "frecency"), let stored = try? JSONDecoder().decode(Frecency.self, from: data) {
            frecency = stored
        } else {
            frecency = Frecency(legacyUsage: d.dictionary(forKey: "usage") as? [String: Int] ?? [:])
            saveFrecency()
        }
        d.removeObject(forKey: "usage")
        // Stored now: the next launch counts as an existing install and must not flip these defaults.
        d.set(hotkey.rawValue, forKey: "hotkey")
        d.set(voiceEnabled, forKey: "voiceEnabled")
        d.set(welcomeShown, forKey: "welcomeShown")
    }
    /// Records a run for ranking. `query` is the typed text, used to learn which result it usually means.
    func record(_ id: String, query: String) {
        recentIDs = [id] + recentIDs.filter { $0 != id }.prefix(39)
        defaults.set(recentIDs, forKey: "recentIDs")
        frecency.record(id, query: query)
        saveFrecency()
    }
    func learn(_ query: String, id: String) {
        learned.record(query, id: id)
        save(learned, "learnedIntents")
    }
    func unlearn(_ query: String) {
        learned.forget(query)
        save(learned, "learnedIntents")
    }
    func clearLearned() {
        learned = LearnedIntents()
        save(learned, "learnedIntents")
    }
    private func save<T: Encodable>(_ value: T, _ key: String) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }
    private static func load<T: Decodable>(_ defaults: UserDefaults, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func saveFrecency() { defaults.set(try? JSONEncoder().encode(frecency), forKey: "frecency") }
    func toggleFavourite(_ id: String) {
        if favourites.contains(id) { favourites.removeAll { $0 == id } } else { favourites.append(id) }
    }
    /// The alert switches as the pure decision logic reads them.
    var automationAlertSettings: AlertSettings {
        AlertSettings(enabled: automationAlerts, failures: automationAlertFailures,
                      quietHours: automationQuietHours ? QuietHours(start: automationQuietStart, end: automationQuietEnd) : nil,
                      hideNames: automationHideNames)
    }
    /// A new agent task with the default runner, model, effort, and access. Fast applies to Codex only.
    func defaultAgentTask(prompt: String = "", workingDirectory: String = "") -> AgentTask {
        AgentTask(runner: automationRunner, prompt: prompt,
                  model: automationRunner == .codex ? automationCodexModel : automationClaudeModel,
                  effort: automationEffort, fast: automationRunner == .codex && automationFast,
                  workingDirectory: workingDirectory, access: automationAccess)
    }
    /// The policy new automations start with.
    var defaultAutomationPolicy: Policy { Policy(timeout: automationTimeoutMinutes * 60, alertOnFailure: automationAlertFailures) }
    var loginStatus: SMAppService.Status { SMAppService.mainApp.status }
    /// Registers or unregisters the login item and returns the resulting status.
    @discardableResult func setLogin(_ enabled: Bool) throws -> SMAppService.Status {
        defer { objectWillChange.send() }
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        return loginStatus
    }
}
