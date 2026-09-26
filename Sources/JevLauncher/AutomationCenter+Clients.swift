import AppKit
import LauncherCore

/// Client metrics sidecars: `clients.json` in the Automations folder, read off the main thread.
/// Displaying metrics never opens the dashboard or makes a network call.
extension AutomationCenter {
    nonisolated static let clientsFile = "clients.json"

    /// The clients configured on first run, when their sidecar files exist.
    nonisolated static func seedClients(home: String = NSHomeDirectory()) -> [ClientConfig] {
        let docs = home + "/Dev/docs"
        let seeds: [(String, String, ClientMetricsProfile, String)] = [
            ("stein-firm", "Stein Firm", .stein, docs + "/4-delivery/clients/shantyl-stevens/meta-ads/stein-firm-dashboard.metrics.json"),
            ("robert-parish", "Robert Parish", .robertParish, docs + "/4-delivery/clients/robert-parish/meta-ads/robert-parish-dashboard.metrics.json"),
            ("redesign", "ReDesign", .redesign, docs + "/2-marketing/paid-ads/meta-ads/redesign-pi-firm-ads/2026-08-01-redesign-meta-ads-dashboard.metrics.json")
        ]
        return seeds.compactMap { id, name, profile, path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return ClientConfig(id: id, name: name, profile: profile, metricsPath: path, dashboardPath: dashboard(besides: path))
        }
    }

    /// `name.metrics.json` → `name.html` in the same folder, when it exists.
    nonisolated static func dashboard(besides metricsPath: String) -> String? {
        guard metricsPath.hasSuffix(".metrics.json") else { return nil }
        let html = String(metricsPath.dropLast(".metrics.json".count)) + ".html"
        return FileManager.default.fileExists(atPath: html) ? html : nil
    }

    /// Reads `clients.json` (seeding it once) and every sidecar, off the main thread.
    func loadClients(seed: Bool) {
        Task { @MainActor [weak self] in await self?.readClientsNow(seed: seed) }
    }

    /// The same, for callers that wait for fresh numbers, such as the launcher's "clients" rows.
    func readClientsNow(seed: Bool = false) async {
        clientReadGeneration += 1
        let generation = clientReadGeneration
        let store = self.store
        let previous = Dictionary(clients.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let isolated = self.isolated
        let entries = await Task.detached(priority: .userInitiated) { () -> [ClientEntry]? in
            var configs = store.readTopFile([ClientConfig].self, name: Self.clientsFile)
            if configs == nil, seed, !isolated, !store.hasTopFile(Self.clientsFile) {
                let seeded = Self.seedClients()
                try? store.writeTopFile(seeded, name: Self.clientsFile)
                configs = seeded
            }
            if configs == nil, isolated { return nil }
            return (configs ?? []).map { Self.read($0, previous: previous[$0.id]) }
        }.value
        guard generation == clientReadGeneration, let entries else { return }
        clients = entries
        if clientViewers > 0 { watchClientFolders() }
    }

    /// One sidecar. A failed read keeps the last good snapshot, marked with the error.
    nonisolated static func read(_ config: ClientConfig, previous: ClientEntry?) -> ClientEntry {
        var entry = ClientEntry(config: config, snapshot: previous?.config == config ? previous?.snapshot : nil, readError: nil, readAt: Date())
        do {
            entry.snapshot = try ClientMetricsReader.read(url: URL(fileURLWithPath: config.metricsPath), profile: config.profile)
        } catch {
            entry.readError = switch error as? ClientMetricsError {
            case .tooLarge: "The metrics file is too large."
            case .notJSONObject: "The metrics file is not valid JSON."
            default: "The metrics file could not be read."
            }
        }
        return entry
    }

    func saveClient(_ config: ClientConfig) {
        var list = clients.map(\.config)
        if let index = list.firstIndex(where: { $0.id == config.id }) { list[index] = config } else { list.append(config) }
        writeClients(list)
    }

    func removeClient(_ id: String) {
        writeClients(clients.map(\.config).filter { $0.id != id })
    }

    private func writeClients(_ list: [ClientConfig]) {
        clientReadGeneration += 1
        guard !isolated else {
            clients = list.map { c in clients.first { $0.id == c.id }.map { var e = $0; e.config = c; return e } ?? ClientEntry(config: c, snapshot: nil, readError: nil, readAt: nil) }
            return
        }
        do { try store.writeTopFile(list, name: Self.clientsFile) } catch { message = "Could not save clients: \(error)"; return }
        loadClients(seed: false)
    }

    /// Queues the client's refresh automation, then reads the sidecar again.
    func refreshClient(_ id: String) {
        guard let entry = clients.first(where: { $0.id == id }) else { return }
        if let automationID = entry.config.automationID, automation(automationID) != nil { runNow(automationID) }
        rereadClient(id)
    }

    /// Reads one sidecar again, without running anything.
    func rereadClient(_ id: String) {
        guard let entry = clients.first(where: { $0.id == id }) else { return }
        clientRefreshGenerations[id, default: 0] += 1
        let refresh = clientRefreshGenerations[id]
        let generation = clientReadGeneration
        Task { @MainActor [weak self] in
            let fresh = await Task.detached(priority: .utility) { Self.read(entry.config, previous: entry) }.value
            guard let self, self.clientReadGeneration == generation, self.clientRefreshGenerations[id] == refresh,
                  let index = self.clients.firstIndex(where: { $0.id == id }), self.clients[index].config == entry.config else { return }
            self.clients[index] = fresh
        }
    }

    func openDashboard(_ id: String) {
        guard let path = clients.first(where: { $0.id == id })?.config.dashboardPath, path.lowercased().hasSuffix(".html"),
              FileManager.default.fileExists(atPath: path) else { message = "No dashboard file is set for this client."; return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Views that show client metrics call this with true on appear and false on disappear.
    /// The sidecar folders are watched only while something shows them.
    func setClientsVisible(_ visible: Bool) {
        clientViewers = max(0, clientViewers + (visible ? 1 : -1))
        if clientViewers > 0 {
            if clientWatches.isEmpty { watchClientFolders(); loadClients(seed: false) }
        } else {
            clientWatches = []
        }
    }

    func watchClientFolders() {
        guard !isolated else { return }
        let folders = Set(clients.map { ($0.config.metricsPath as NSString).deletingLastPathComponent })
        clientWatches = folders.sorted().compactMap { folder in
            DirectoryWatch(URL(fileURLWithPath: folder)) { [weak self] in
                MainActor.assumeIsolated { self?.clientFolderChanged(folder) }
            }
        }
    }

    private func clientFolderChanged(_ folder: String) {
        for entry in clients where (entry.config.metricsPath as NSString).deletingLastPathComponent == folder { rereadClient(entry.id) }
    }
}
