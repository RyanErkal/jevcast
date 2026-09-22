import AppKit
import Combine

struct AppEntry: Codable, Identifiable, Sendable {
    let path: String
    let name: String
    let bundleID: String?
    var id: String { "app:" + path }
}

@MainActor
final class AppCatalogue: ObservableObject {
    @Published private(set) var entries: [AppEntry] = []
    @Published private(set) var scanning = false
    private(set) var runningApplications: [NSRunningApplication] = []
    private var task: Task<Void, Never>?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var runningTokens: [NSObjectProtocol] = []
    private var extraFolders: [String] = []
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("JevLauncher/apps.json")
    init(loadCache: Bool = true) {
        if loadCache, let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([AppEntry].self, from: data) {
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
        task?.cancel()
        scanning = true
        let roots = Array(Set(["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", "/System/Library/CoreServices/Finder.app", NSHomeDirectory() + "/Applications"] + extra))
        let cache = cacheURL
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.scan(roots: roots)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.entries = result
            self.scanning = false
            self.watch(roots: roots)
            Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(result).write(to: cache, options: .atomic)
                } catch { /* A missing cache never prevents launching. */ }
            }
        }
    }
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
            let rootURL = URL(fileURLWithPath: root)
            if rootURL.pathExtension.lowercased() == "app" { addApp(rootURL); continue }
            guard let iterator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: []) else { continue }
            for case let url as URL in iterator {
                if url.lastPathComponent.hasPrefix(".") { iterator.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" {
                    iterator.skipDescendants()
                    addApp(url)
                } else if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                    iterator.skipDescendants()
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func watch(roots: [String]) {
        sources.forEach { $0.cancel() }; sources = []
        // Watch catalogue directories, including Utilities; never poll the disk while idle.
        let parents = entries.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
        for root in Set(roots + parents) {
            let descriptor = open(root, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in guard let self else { return }; self.refresh(extra: self.extraFolders) }
            }
            source.setCancelHandler { close(descriptor) }
            sources.append(source); source.resume()
        }
    }
}
