import AppKit
import LauncherCore

/// Dashboards: `dashboards.json` in the Automations folder, each card reading one local JSON file off the main thread.
/// Showing a card never opens its file or makes a network call.
extension AutomationCenter {
    nonisolated static let dashboardsFile = "dashboards.json"
    /// The file older versions used. Read once to migrate, and left in place.
    nonisolated static let legacyClientsFile = "clients.json"

    /// Reads `dashboards.json` (migrating `clients.json` once) and every card's file, off the main thread.
    func loadDashboards(migrate: Bool) {
        Task { @MainActor [weak self] in await self?.readDashboardsNow(migrate: migrate) }
    }

    /// The same, for callers that wait for fresh numbers, such as the launcher's "dashboards" rows.
    func readDashboardsNow(migrate: Bool = false) async {
        dashboardReadGeneration += 1
        let generation = dashboardReadGeneration
        let store = self.store
        let previous = Dictionary(dashboards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let isolated = self.isolated
        let entries = await Task.detached(priority: .userInitiated) { () -> [DashboardEntry]? in
            var configs = store.readTopFile([DashboardConfig].self, name: Self.dashboardsFile)
            if configs == nil, migrate, !isolated, !store.hasTopFile(Self.dashboardsFile),
               let migrated = Self.migratedLegacy(store) {
                try? store.writeTopFile(migrated, name: Self.dashboardsFile)
                configs = migrated
            }
            if configs == nil, isolated { return nil }
            return (configs ?? []).map { Self.read($0, previous: previous[$0.id]) }
        }.value
        guard generation == dashboardReadGeneration, let entries else { return }
        dashboards = entries
        if dashboardViewers > 0 { watchDashboardFolders() }
    }

    /// Dashboards made from the old `clients.json`, or nil when there is none.
    nonisolated static func migratedLegacy(_ store: AutomationStore) -> [DashboardConfig]? {
        guard let data = store.readTopData(legacyClientsFile) else { return nil }
        return DashboardMigration.migrate(legacy: data)
    }

    /// One card's file. A failed read keeps the last good snapshot, marked with the error.
    nonisolated static func read(_ config: DashboardConfig, previous: DashboardEntry?) -> DashboardEntry {
        var entry = DashboardEntry(config: config, snapshot: previous?.config == config ? previous?.snapshot : nil, readError: nil, readAt: Date())
        do {
            entry.snapshot = try DashboardReader.read(url: URL(fileURLWithPath: config.filePath), config: config)
        } catch {
            entry.readError = switch error as? DashboardReadError {
            case .tooLarge: "The file is too large."
            case .notJSON: "The file is not valid JSON."
            default: "The file could not be read."
            }
        }
        return entry
    }

    func saveDashboard(_ config: DashboardConfig) {
        var list = dashboards.map(\.config)
        if let index = list.firstIndex(where: { $0.id == config.id }) { list[index] = config } else { list.append(config) }
        writeDashboards(list)
    }

    func removeDashboard(_ id: String) {
        writeDashboards(dashboards.map(\.config).filter { $0.id != id })
    }

    private func writeDashboards(_ list: [DashboardConfig]) {
        dashboardReadGeneration += 1
        guard !isolated else {
            dashboards = list.map { c in
                dashboards.first { $0.id == c.id }.map { var e = $0; e.config = c; return e } ?? DashboardEntry(config: c, snapshot: nil, readError: nil, readAt: nil)
            }
            return
        }
        do { try store.writeTopFile(list, name: Self.dashboardsFile) } catch { message = "Could not save dashboards: \(error)"; return }
        loadDashboards(migrate: false)
    }

    /// Queues the card's refresh automation, then reads the file again.
    func refreshDashboard(_ id: String) {
        guard let entry = dashboards.first(where: { $0.id == id }) else { return }
        if let automationID = entry.config.automationID, automation(automationID) != nil { runNow(automationID) }
        rereadDashboard(id)
    }

    /// Reads one card's file again, without running anything.
    func rereadDashboard(_ id: String) {
        guard let entry = dashboards.first(where: { $0.id == id }) else { return }
        dashboardRefreshGenerations[id, default: 0] += 1
        let refresh = dashboardRefreshGenerations[id]
        let generation = dashboardReadGeneration
        Task { @MainActor [weak self] in
            let fresh = await Task.detached(priority: .utility) { Self.read(entry.config, previous: entry) }.value
            guard let self, self.dashboardReadGeneration == generation, self.dashboardRefreshGenerations[id] == refresh,
                  let index = self.dashboards.firstIndex(where: { $0.id == id }), self.dashboards[index].config == entry.config else { return }
            self.dashboards[index] = fresh
        }
    }

    /// Opens the card's linked file in its default app. Only an existing regular file, never a program.
    func openDashboardFile(_ id: String) {
        guard let path = dashboards.first(where: { $0.id == id })?.config.openPath, !path.isEmpty else {
            message = "No file to open is set for this dashboard."; return
        }
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              !FileManager.default.isExecutableFile(atPath: path), !Self.runnableExtensions.contains(url.pathExtension.lowercased()) else {
            message = "The file to open is missing or is a program."; return
        }
        NSWorkspace.shared.open(url)
    }

    /// Files that would run something when opened. The card never opens these.
    nonisolated static let runnableExtensions: Set<String> = ["app", "command", "tool", "sh", "zsh", "terminal", "workflow", "scpt", "applescript", "pkg", "dmg"]

    /// Views that show dashboards call this with true on appear and false on disappear.
    /// The files' folders are watched only while something shows them.
    func setDashboardsVisible(_ visible: Bool) {
        dashboardViewers = max(0, dashboardViewers + (visible ? 1 : -1))
        if dashboardViewers > 0 {
            if dashboardWatches.isEmpty { watchDashboardFolders(); loadDashboards(migrate: false) }
        } else {
            dashboardWatches = []
        }
    }

    func watchDashboardFolders() {
        guard !isolated else { return }
        let folders = Set(dashboards.map { ($0.config.filePath as NSString).deletingLastPathComponent })
        dashboardWatches = folders.sorted().compactMap { folder in
            DirectoryWatch(URL(fileURLWithPath: folder)) { [weak self] in
                MainActor.assumeIsolated { self?.dashboardFolderChanged(folder) }
            }
        }
    }

    private func dashboardFolderChanged(_ folder: String) {
        for entry in dashboards where (entry.config.filePath as NSString).deletingLastPathComponent == folder { rereadDashboard(entry.id) }
    }
}
