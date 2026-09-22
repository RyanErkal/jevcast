import AppKit
import Combine

struct AppEntry: Codable, Identifiable, Sendable {
    let path: String
    let name: String
    let bundleID: String?
    /// A non-file URL that opens this entry, such as a System Settings pane.
    /// `nil` for installed apps, which open from ``path``.
    var launchURL: String? = nil
    var id: String { "app:" + (launchURL ?? path) }
}

@MainActor
final class AppCatalogue: ObservableObject {
    @Published private(set) var entries: [AppEntry] = []
    @Published private(set) var scanning = false
    private(set) var runningApplications: [NSRunningApplication] = []
    private var task: Task<Void, Never>?
    private let rescan = CatalogueDebouncer(delay: .seconds(1))
    private var sources: [DispatchSourceFileSystemObject] = []
    private var runningTokens: [NSObjectProtocol] = []
    private var extraFolders: [String] = []
    nonisolated static let standardRoots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", "/System/Library/CoreServices/Finder.app", NSHomeDirectory() + "/Applications"]
    private let baseRoots: [String]
    /// Nil for a catalogue that must not replace the user's cache, such as the demo one.
    private let cacheURL: URL?
    init(loadCache: Bool = true, roots: [String] = AppCatalogue.standardRoots, persistsCache: Bool = true) {
        baseRoots = roots
        cacheURL = persistsCache ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JevLauncher/apps.json") : nil
        if loadCache, let cacheURL, let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([AppEntry].self, from: data) {
            entries = cached
        }
        runningApplications = NSWorkspace.shared.runningApplications
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            runningTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.runningApplications = NSWorkspace.shared.runningApplications
                    self?.objectWillChange.send()
                }
            })
        }
    }
    func refresh(extra: [String]) {
        extraFolders = extra
        rescan.cancel()
        task?.cancel()
        scanning = true
        let roots = Array(Set(baseRoots + extra))
        let cache = cacheURL
        let scan = Task.detached(priority: .utility) { () -> [AppEntry]? in
            let apps = Self.scan(roots: roots)
            let panes = CatalogueSettingsPanes.entries()
            return Task.isCancelled ? nil : Self.sorted(apps + panes)
        }
        task = Task { [weak self] in
            // A detached task does not inherit cancellation. Forward it so
            // cancel() stops the scan loop, not only this waiting task.
            let result = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, let result, let self else { return }
            self.entries = result
            self.scanning = false
            self.watch(roots: roots)
            guard let cache else { return }
            Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(result).write(to: cache, options: .atomic)
                } catch { /* A missing cache never prevents launching. */ }
            }
        }
    }
    /// Scans ``roots`` for app bundles. Returns an empty list as soon as the
    /// calling task is cancelled.
    nonisolated static func scan(roots: [String]) -> [AppEntry] {
        var paths = Set<String>()
        var result: [AppEntry] = []
        let fm = FileManager.default
        func addApp(_ url: URL) {
            let canonical = url.resolvingSymlinksInPath().path
            guard fm.fileExists(atPath: canonical), paths.insert(canonical).inserted else { return }
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            result.append(AppEntry(path: canonical, name: name, bundleID: bundle?.bundleIdentifier))
        }
        for root in roots {
            if Task.isCancelled { return [] }
            let rootURL = URL(fileURLWithPath: root)
            if rootURL.pathExtension.lowercased() == "app" { addApp(rootURL); continue }
            guard let iterator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: []) else { continue }
            for case let url as URL in iterator {
                if Task.isCancelled { return [] }
                if url.lastPathComponent.hasPrefix(".") { iterator.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" {
                    iterator.skipDescendants()
                    addApp(url)
                } else if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                    iterator.skipDescendants()
                }
            }
        }
        return sorted(result)
    }
    nonisolated static func sorted(_ entries: [AppEntry]) -> [AppEntry] {
        entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func watch(roots: [String]) {
        sources.forEach { $0.cancel() }; sources = []
        // Watch catalogue directories, including Utilities; never poll the disk while idle.
        let parents = entries.filter { $0.launchURL == nil }.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
        for root in Set(roots + parents) {
            let descriptor = open(root, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            // Installs and updates emit bursts of events; rescan once they settle.
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rescan.schedule { [weak self] in
                        guard let self else { return }
                        self.refresh(extra: self.extraFolders)
                    }
                }
            }
            source.setCancelHandler { close(descriptor) }
            sources.append(source); source.resume()
        }
    }
}
