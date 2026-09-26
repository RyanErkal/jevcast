import Foundation

/// Files under `~/Library/Application Support/Jevcast/Automations`. Shared by the app and the runner.
///
/// Thread safety: every public method takes an internal lock, so one instance may be used from any thread.
/// Between processes, each file is replaced atomically (temp file + rename); readers always see a whole file.
public final class AutomationStore: @unchecked Sendable {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jevcast/Automations", isDirectory: true)
    }

    public let root: URL
    private let lock = NSLock()

    public init(root: URL = AutomationStore.defaultRoot) { self.root = root }

    // MARK: Automations

    public func loadAutomations() -> (automations: [Automation], problems: [String: String]) {
        locked {
            var list: [Automation] = [], problems: [String: String] = [:]
            for name in automationFolderNames() {
                do {
                    guard let data = try SecureFile.read(folder(name).appendingPathComponent("automation.json"), maxBytes: SecureFile.maxJSON)
                    else { problems[name] = "automation.json is missing."; continue }
                    let a = try AutomationJSON.decoder().decode(Automation.self, from: data)
                    guard a.id == name else { problems[name] = "The ID inside does not match the folder."; continue }
                    guard a.version <= Automation.formatVersion else { problems[name] = "Made by a newer Jevcast."; continue }
                    list.append(a)
                } catch { problems[name] = "\(error)" }
            }
            return (list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, problems)
        }
    }

    public func automation(id: String) -> Automation? {
        guard AutomationID.isValid(id) else { return nil }
        return locked {
            guard let data = try? SecureFile.read(folder(id).appendingPathComponent("automation.json"), maxBytes: SecureFile.maxJSON)
            else { return nil }
            return try? AutomationJSON.decoder().decode(Automation.self, from: data)
        }
    }

    /// Writes the definition as given. The caller manages `revision` and `updated`.
    public func save(_ automation: Automation) throws {
        try locked {
            let dir = try automationDir(automation.id, create: true)
            try SecureFile.write(try AutomationJSON.encoder().encode(automation), to: dir.appendingPathComponent("automation.json"))
        }
    }

    /// Moves the automation's folder, with its runs, to the Trash.
    public func remove(id: String) throws {
        try locked {
            let dir = try automationDir(id, create: false)
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        }
    }

    public func state(for id: String) -> AutomationState {
        guard AutomationID.isValid(id) else { return AutomationState() }
        return locked {
            guard let data = try? SecureFile.read(folder(id).appendingPathComponent("state.json"), maxBytes: SecureFile.maxJSON),
                  let s = try? AutomationJSON.decoder().decode(AutomationState.self, from: data) else { return AutomationState() }
            return s
        }
    }

    public func saveState(_ state: AutomationState, for id: String) throws {
        try locked {
            let dir = try automationDir(id, create: true)
            try SecureFile.write(try AutomationJSON.encoder().encode(state), to: dir.appendingPathComponent("state.json"))
        }
    }

    // MARK: Runs

    /// Newest first.
    public func runs(for id: String, limit: Int) -> [RunRecord] {
        guard AutomationID.isValid(id), limit > 0 else { return [] }
        return locked { loadRuns(id, limit: limit) }
    }

    /// Newest first across every automation.
    public func allRecentRuns(limit: Int) -> [RunRecord] {
        guard limit > 0 else { return [] }
        return locked {
            let all = automationFolderNames().flatMap { loadRuns($0, limit: limit) }
            return Array(all.sorted { ($0.queued, $0.id) > ($1.queued, $1.id) }.prefix(limit))
        }
    }

    public func run(automationID: String, runID: String) -> RunRecord? {
        guard AutomationID.isValid(automationID), RunID.isValid(runID) else { return nil }
        return locked { loadRun(automationID, runID) }
    }

    public func saveRun(_ run: RunRecord) throws {
        try locked {
            let dir = try runDir(run.automationID, run.id, create: true)
            try SecureFile.write(try AutomationJSON.encoder().encode(run), to: dir.appendingPathComponent("run.json"))
        }
    }

    /// The run's folder. Not created. Returns a path under a placeholder when the IDs are invalid, so callers cannot escape the root.
    public func runFolder(automationID: String, runID: String) -> URL {
        guard AutomationID.isValid(automationID), RunID.isValid(runID) else { return root.appendingPathComponent("invalid", isDirectory: true) }
        return folder(automationID).appendingPathComponent("runs", isDirectory: true).appendingPathComponent(runID, isDirectory: true)
    }

    public func readOutput(_ run: RunRecord) -> String? {
        guard let name = run.outputFile,
              let data = try? readRunFile(automationID: run.automationID, runID: run.id, name: name, maxBytes: SecureFile.maxOutput)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes one file (0600) inside the run folder, creating the folder.
    public func writeRunFile(automationID: String, runID: String, name: String, data: Data) throws {
        guard SecureFile.isSafeName(name) else { throw AutomationStoreError.invalidID(name) }
        try locked {
            let dir = try runDir(automationID, runID, create: true)
            try SecureFile.write(data, to: dir.appendingPathComponent(name))
        }
    }

    public func readRunFile(automationID: String, runID: String, name: String, maxBytes: Int = 2 * 1024 * 1024) throws -> Data? {
        guard SecureFile.isSafeName(name) else { throw AutomationStoreError.invalidID(name) }
        return try locked {
            let dir = try runDir(automationID, runID, create: false)
            return try SecureFile.read(dir.appendingPathComponent(name), maxBytes: maxBytes)
        }
    }

    // MARK: Requests

    public func submit(_ request: RunnerRequest) throws {
        guard RunID.isValid(request.id) else { throw AutomationStoreError.invalidID(request.id) }
        try locked {
            let dir = try requestsDir(create: true)
            try SecureFile.write(try AutomationJSON.encoder().encode(request), to: dir.appendingPathComponent(request.id + ".json"))
        }
    }

    /// Oldest first. Unreadable files are skipped and left for `removeRequest`.
    public func pendingRequests() -> [RunnerRequest] {
        locked {
            guard let dir = try? requestsDir(create: false),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
            let list: [RunnerRequest] = names.prefix(1000).compactMap { name in
                guard name.hasSuffix(".json"), RunID.isValid(String(name.dropLast(5))),
                      let data = try? SecureFile.read(dir.appendingPathComponent(name), maxBytes: 64 * 1024),
                      let r = try? AutomationJSON.decoder().decode(RunnerRequest.self, from: data),
                      r.id + ".json" == name else { return nil }
                return r
            }
            return list.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
        }
    }

    /// IDs of request files that could not be read, so the runner can drop them.
    public func unreadableRequestIDs() -> [String] {
        let good = Set(pendingRequests().map(\.id))
        return locked {
            guard let dir = try? requestsDir(create: false),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
            return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.filter { RunID.isValid($0) && !good.contains($0) }
        }
    }

    public func removeRequest(id: String) {
        guard RunID.isValid(id) else { return }
        locked {
            guard let dir = try? requestsDir(create: false) else { return }
            unlink(dir.appendingPathComponent(id + ".json").path)
        }
    }

    // MARK: Settings and heartbeat

    public func loadSettings() -> AutomationSettings {
        locked { decodeTop("settings.json") ?? AutomationSettings() }
    }

    public func saveSettings(_ settings: AutomationSettings) throws {
        try locked { try encodeTop(settings, "settings.json") }
    }

    public func readHeartbeat() -> RunnerHeartbeat? { locked { decodeTop("runner.json") } }

    public func writeHeartbeat(_ heartbeat: RunnerHeartbeat) throws {
        try locked { try encodeTop(heartbeat, "runner.json") }
    }

    // MARK: Other files in the root

    /// Reads a small JSON file directly in the root, such as `clients.json`. Nil when missing or unreadable.
    public func readTopFile<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard SecureFile.isSafeName(name) else { return nil }
        return locked { decodeTop(name) }
    }

    /// Writes a JSON file (0600) directly in the root, creating the root.
    public func writeTopFile<T: Encodable>(_ value: T, name: String) throws {
        guard SecureFile.isSafeName(name), !["settings.json", "runner.json"].contains(name) else { throw AutomationStoreError.invalidID(name) }
        try locked { try encodeTop(value, name) }
    }

    /// True when a file with this name exists directly in the root.
    public func hasTopFile(_ name: String) -> Bool {
        guard SecureFile.isSafeName(name) else { return false }
        return locked { (try? SecureFile.read(root.appendingPathComponent(name), maxBytes: SecureFile.maxJSON)) != nil }
    }

    /// Creates the root folder (0700) when it is missing.
    public func ensureRoot() throws {
        try locked { try createParentsOfRoot(); try SecureFile.ensureDirectory(root) }
    }

    // MARK: Prune

    /// Deletes finished runs beyond each automation's `keepRuns` or older than `historyDays`.
    /// Active runs and runs waiting for the user are never removed. Returns how many were removed.
    @discardableResult
    public func prune(now: Date, settings: AutomationSettings) -> Int {
        locked {
            var removed = 0
            let cutoff = now.addingTimeInterval(-Double(max(settings.historyDays, 1)) * 86400)
            for id in automationFolderNames() {
                let keep: Int = {
                    guard let data = try? SecureFile.read(folder(id).appendingPathComponent("automation.json"), maxBytes: SecureFile.maxJSON),
                          let a = try? AutomationJSON.decoder().decode(Automation.self, from: data) else { return Policy().keepRuns }
                    return max(a.policy.keepRuns, 1)
                }()
                for (index, run) in loadRuns(id, limit: 100_000).enumerated() {
                    guard run.state.isFinished else { continue }
                    let old = (run.finished ?? run.queued) < cutoff
                    guard index >= keep || old else { continue }
                    if (try? FileManager.default.removeItem(at: runFolder(automationID: id, runID: run.id))) != nil { removed += 1 }
                }
            }
            return removed
        }
    }

    /// Deletes every finished run folder now, for "Delete finished history". Active runs and runs
    /// waiting for the user stay. Returns how many were removed.
    @discardableResult
    public func removeFinishedRuns() -> Int {
        locked {
            var removed = 0
            for id in automationFolderNames() {
                for run in loadRuns(id, limit: 100_000) where run.state.isFinished {
                    if (try? FileManager.default.removeItem(at: runFolder(automationID: id, runID: run.id))) != nil { removed += 1 }
                }
            }
            return removed
        }
    }

    // MARK: Private helpers (call with the lock held)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func automationDir(_ id: String, create: Bool) throws -> URL {
        guard AutomationID.isValid(id) else { throw AutomationStoreError.invalidID(id) }
        let dir = folder(id)
        if create {
            try createParentsOfRoot()
            try SecureFile.ensureDirectory(root)
            try SecureFile.ensureDirectory(dir)
        } else {
            guard try SecureFile.isDirectory(root), try SecureFile.isDirectory(dir) else { throw AutomationStoreError.io("No automation \(id)") }
        }
        return dir
    }

    private func runDir(_ automationID: String, _ runID: String, create: Bool) throws -> URL {
        guard RunID.isValid(runID) else { throw AutomationStoreError.invalidID(runID) }
        let base = try automationDir(automationID, create: create)
        let runs = base.appendingPathComponent("runs", isDirectory: true)
        let dir = runs.appendingPathComponent(runID, isDirectory: true)
        if create {
            try SecureFile.ensureDirectory(runs); try SecureFile.ensureDirectory(dir)
        } else {
            guard try SecureFile.isDirectory(runs), try SecureFile.isDirectory(dir) else { throw AutomationStoreError.io("No run \(runID)") }
        }
        return dir
    }

    private func requestsDir(create: Bool) throws -> URL {
        let dir = root.appendingPathComponent("requests", isDirectory: true)
        if create {
            try createParentsOfRoot(); try SecureFile.ensureDirectory(root); try SecureFile.ensureDirectory(dir)
        } else {
            guard try SecureFile.isDirectory(root), try SecureFile.isDirectory(dir) else { throw AutomationStoreError.io("No requests") }
        }
        return dir
    }

    /// `Application Support/Jevcast` may not exist yet. Parents are created normally; the root itself is checked.
    private func createParentsOfRoot() throws {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func automationFolderNames() -> [String] {
        guard (try? SecureFile.isDirectory(root)) == true,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { AutomationID.isValid($0) && $0 != "requests" && ((try? SecureFile.isDirectory(folder($0))) == true) }.sorted()
    }

    private func loadRuns(_ id: String, limit: Int) -> [RunRecord] {
        let runs = folder(id).appendingPathComponent("runs", isDirectory: true)
        guard (try? SecureFile.isDirectory(folder(id))) == true, (try? SecureFile.isDirectory(runs)) == true,
              let names = try? FileManager.default.contentsOfDirectory(atPath: runs.path) else { return [] }
        var list: [RunRecord] = []
        for name in names.filter(RunID.isValid).sorted(by: >) {
            if let r = loadRun(id, name) { list.append(r) }
            if list.count >= limit { break }
        }
        return list
    }

    private func loadRun(_ automationID: String, _ runID: String) -> RunRecord? {
        guard let dir = try? runDir(automationID, runID, create: false),
              let data = try? SecureFile.read(dir.appendingPathComponent("run.json"), maxBytes: SecureFile.maxJSON),
              let run = try? AutomationJSON.decoder().decode(RunRecord.self, from: data),
              run.id == runID, run.automationID == automationID else { return nil }
        return run
    }

    private func decodeTop<T: Decodable>(_ name: String) -> T? {
        guard (try? SecureFile.isDirectory(root)) == true,
              let data = try? SecureFile.read(root.appendingPathComponent(name), maxBytes: SecureFile.maxJSON) else { return nil }
        return try? AutomationJSON.decoder().decode(T.self, from: data)
    }

    private func encodeTop<T: Encodable>(_ value: T, _ name: String) throws {
        try createParentsOfRoot(); try SecureFile.ensureDirectory(root)
        try SecureFile.write(try AutomationJSON.encoder().encode(value), to: root.appendingPathComponent(name))
    }
}
