import AppKit
import Combine
import ServiceManagement

@MainActor
final class Preferences: ObservableObject {
    @Published var hotkey: Int { didSet { defaults.set(hotkey, forKey: "hotkey") } }
    @Published var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: "voiceEnabled") } }
    @Published var jevEnabled: Bool { didSet { defaults.set(jevEnabled, forKey: "jevEnabled") } }
    @Published var edgeSnapping: Bool { didSet { defaults.set(edgeSnapping, forKey: "edgeSnapping") } }
    @Published var windowShortcuts: Bool { didSet { defaults.set(windowShortcuts, forKey: "windowShortcuts") } }
    @Published var gap: Double { didSet { defaults.set(gap, forKey: "gap") } }
    @Published var webEngine: String { didSet { defaults.set(webEngine, forKey: "webEngine") } }
    @Published var appFolders: [String] { didSet { defaults.set(appFolders, forKey: "appFolders") } }
    @Published var fileFolders: [String] { didSet { defaults.set(fileFolders, forKey: "fileFolders") } }
    @Published var favourites: [String] { didSet { defaults.set(favourites, forKey: "favourites") } }
    @Published var aliases: [String: String] { didSet { defaults.set(aliases, forKey: "aliases") } }
    @Published private(set) var usage: [String: Int]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        hotkey = d.integer(forKey: "hotkey")
        voiceEnabled = d.object(forKey: "voiceEnabled") as? Bool ?? true
        jevEnabled = d.bool(forKey: "jevEnabled")
        edgeSnapping = d.bool(forKey: "edgeSnapping")
        windowShortcuts = d.bool(forKey: "windowShortcuts")
        gap = d.object(forKey: "gap") as? Double ?? 8
        webEngine = d.string(forKey: "webEngine") ?? "Google"
        appFolders = d.stringArray(forKey: "appFolders") ?? []
        fileFolders = d.stringArray(forKey: "fileFolders") ?? [NSHomeDirectory()]
        favourites = d.stringArray(forKey: "favourites") ?? []
        aliases = d.dictionary(forKey: "aliases") as? [String: String] ?? [:]
        usage = d.dictionary(forKey: "usage") as? [String: Int] ?? [:]
    }
    func record(_ id: String) {
        usage[id, default: 0] += 1
        defaults.set(usage, forKey: "usage")
    }
    func toggleFavourite(_ id: String) {
        if favourites.contains(id) { favourites.removeAll { $0 == id } } else { favourites.append(id) }
    }
    func addFolder(apps: Bool) {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        if picker.runModal() == .OK {
            let paths = picker.urls.map(\.path)
            if apps { appFolders = Array(Set(appFolders + paths)).sorted() }
            else { fileFolders = Array(Set(fileFolders + paths)).sorted() }
        }
    }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }
}
