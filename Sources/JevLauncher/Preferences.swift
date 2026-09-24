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
    /// Luna writes and reads text when a request needs it. Off until the user turns it on.
    @Published var lunaEnabled: Bool { didSet { defaults.set(lunaEnabled, forKey: "lunaEnabled") } }
    @Published var lunaEffort: LunaEffort { didSet { defaults.set(lunaEffort.rawValue, forKey: "lunaEffort") } }
    /// Each kind of context Luna may receive. What the user types is always allowed once Luna is on.
    @Published var lunaSendsSelection: Bool { didSet { defaults.set(lunaSendsSelection, forKey: "lunaSendsSelection") } }
    @Published var lunaSendsMail: Bool { didSet { defaults.set(lunaSendsMail, forKey: "lunaSendsMail") } }
    @Published var lunaSendsCalendar: Bool { didSet { defaults.set(lunaSendsCalendar, forKey: "lunaSendsCalendar") } }
    @Published var lunaSendsUnreadMail: Bool { didSet { defaults.set(lunaSendsUnreadMail, forKey: "lunaSendsUnreadMail") } }
    /// Luna cleans dictation transcripts. Off until the user turns it on.
    @Published var lunaSendsDictation: Bool { didSet { defaults.set(lunaSendsDictation, forKey: "lunaSendsDictation") } }
    /// Hold Right Command to dictate into the front app. Off until the user turns it on.
    @Published var dictationEnabled: Bool { didSet { defaults.set(dictationEnabled, forKey: "dictationEnabled") } }
    @Published var dictationRetention: DictationRetention { didSet { defaults.set(dictationRetention.rawValue, forKey: "dictationRetention") } }
    @Published var edgeSnapping: Bool { didSet { defaults.set(edgeSnapping, forKey: "edgeSnapping") } }
    @Published var windowShortcuts: Bool { didSet { defaults.set(windowShortcuts, forKey: "windowShortcuts") } }
    @Published var gap: Double { didSet { defaults.set(gap, forKey: "gap") } }
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
        lunaEnabled = d.bool(forKey: "lunaEnabled")
        lunaEffort = d.string(forKey: "lunaEffort").flatMap(LunaEffort.init(rawValue:)) ?? .fast
        lunaSendsSelection = d.bool(forKey: "lunaSendsSelection")
        lunaSendsMail = d.bool(forKey: "lunaSendsMail")
        lunaSendsCalendar = d.bool(forKey: "lunaSendsCalendar")
        lunaSendsUnreadMail = d.bool(forKey: "lunaSendsUnreadMail")
        lunaSendsDictation = d.bool(forKey: "lunaSendsDictation")
        dictationEnabled = d.bool(forKey: "dictationEnabled")
        dictationRetention = d.string(forKey: "dictationRetention").flatMap(DictationRetention.init(rawValue:)) ?? .days30
        edgeSnapping = d.bool(forKey: "edgeSnapping")
        windowShortcuts = d.bool(forKey: "windowShortcuts")
        gap = d.object(forKey: "gap") as? Double ?? 8
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
    var loginStatus: SMAppService.Status { SMAppService.mainApp.status }
    /// Registers or unregisters the login item and returns the resulting status.
    @discardableResult func setLogin(_ enabled: Bool) throws -> SMAppService.Status {
        defer { objectWillChange.send() }
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        return loginStatus
    }
}
