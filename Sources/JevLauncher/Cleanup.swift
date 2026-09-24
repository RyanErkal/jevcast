import AppKit
import LauncherCore

/// "cleanup" or "cool down": a checklist of background work to stop, such as simulators nobody
/// is looking at, idle dev servers, and leftover dev processes. Manual only: nothing stops until
/// you press Return on the Clean Up row. Protected apps and everything they started stay running.
@MainActor
enum Cleanup {
    /// Apps whose whole process tree is always kept, such as your editor and browser.
    static let protectedApps = ["com.t3tools.t3code", "com.google.Chrome", "com.openai.codex", "com.apple.finder",
                                "com.apple.mail", "com.apple.Terminal", "com.mitchellh.ghostty"]

    struct Item: Identifiable {
        let finding: CleanupFinding
        /// Simulator UDIDs to shut down, or an app to quit, instead of PIDs to stop.
        var simulators: [String] = []
        var app: NSRunningApplication?
        var id: String { finding.key }
    }

    /// Reads the Mac. Runs off the main thread except for the running-apps list.
    static func scan(ignored: Set<String>) async -> [Item] {
        let apps = NSWorkspace.shared.runningApplications
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let protectedRoots = Set(apps.filter { app in
            app.bundleIdentifier.map(protectedApps.contains) == true || app.processIdentifier == front || app.processIdentifier == getpid()
        }.map(\.processIdentifier))
        async let psOutput = try? CommandRunner.capture(["/bin/ps"] + CleanupProcess.psArguments, allowFailure: true, timeout: 10)
        async let launchd = try? CommandRunner.capture(["/bin/launchctl", "list"], allowFailure: true, timeout: 10)
        async let simJSON = try? CommandRunner.capture(["/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j"], allowFailure: true, timeout: 20)
        async let ports = CommandRunner.listeningPorts()
        let processes = CleanupProcess.parse(await psOutput ?? "")
        let launchdPIDs = Set(LaunchStatus.parse(await launchd ?? "").values.compactMap(\.pid))
        var listening: [Int32: [Int]] = [:]
        for port in await ports { listening[port.pid, default: []].append(port.port) }

        var items: [Item] = []
        // Simulators: all booted devices are one item. A running xcodebuild means tests use them.
        let booted = CleanupRules.bootedSimulators(Data((await simJSON ?? "").utf8))
        if !booted.isEmpty, !ignored.contains("simulators") {
            let testing = processes.contains { $0.name == "xcodebuild" }
            let memory = processes.filter { $0.path.contains("/RuntimeRoot/") || $0.name.hasSuffix("_sim") }.map(\.memoryMB).reduce(0, +)
            let names = booted.map(\.name)
            let detail = (names.count <= 3 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more")
                + (testing ? " · xcodebuild is running, so they may be in use" : "")
            items.append(Item(finding: CleanupFinding(group: .simulator, key: "simulators", title: "\(booted.count) iOS simulator" + (booted.count == 1 ? "" : "s"),
                                                      detail: detail, pids: [], memoryMB: memory, checked: !testing),
                              simulators: booted.map(\.udid)))
        }
        // Docker Desktop with nothing running inside it.
        if let docker = apps.first(where: { $0.bundleIdentifier == "com.docker.docker" }), !ignored.contains("docker") {
            // "x" stands for "unknown", so Docker is offered only when the CLI answers with no containers.
            let cli = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
            var containers = "x"
            if let cli { containers = (try? await CommandRunner.capture([cli, "ps", "-q"], timeout: 10)) ?? "x" }
            if containers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let memory = processes.filter { $0.path.contains("Docker.app") }.map(\.memoryMB).reduce(0, +)
                items.append(Item(finding: CleanupFinding(group: .docker, key: "docker", title: "Docker Desktop", detail: "No containers running",
                                                          pids: [], memoryMB: memory, checked: true), app: docker))
            }
        }
        let findings = CleanupRules.find(.init(processes: processes, uid: getuid(), listening: listening, launchdPIDs: launchdPIDs,
                                               protectedRoots: protectedRoots, ignoredKeys: ignored))
        items += findings.map { Item(finding: $0) }
        return items
    }

    /// Stops one item politely: SIGTERM, a simulator shutdown, or an app quit. Returns what it did.
    static func stop(_ item: Item) async -> String {
        if !item.simulators.isEmpty {
            for udid in item.simulators { _ = try? await CommandRunner.capture(["/usr/bin/xcrun", "simctl", "shutdown", udid], allowFailure: true, timeout: 60) }
            // Simulator.app itself holds memory once its devices are off.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").forEach { $0.terminate() }
            return item.finding.title + " shut down"
        }
        if let app = item.app { app.terminate(); return item.finding.title + " quit" }
        // The main process first, so it can stop its own children; then any child still running.
        guard let main = item.finding.pids.first else { return "" }
        kill(main, SIGTERM)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for pid in item.finding.pids.dropFirst() where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
        return item.finding.title + " stopped"
    }

    /// Free plus inactive memory, in MB: what apps can use at once. Measured before and after a
    /// cleanup, because summing each process's memory counts shared memory more than once.
    nonisolated static func availableMB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(UInt64(stats.free_count) + UInt64(stats.inactive_count)) * Double(vm_kernel_page_size) / 1_048_576
    }

    static func size(_ megabytes: Double) -> String {
        megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : "\(Int(megabytes)) MB"
    }
}

/// The cleanup checklist in the launcher. Return on an item checks or unchecks it; Return on the
/// top row stops everything checked. ⌘K offers Stop Now and Always Ignore for each item.
@MainActor
final class CleanupSource: ThingSource {
    let section = "Clean Up"
    private let preferences: Preferences
    private var cache: (at: Date, items: [Cleanup.Item])?
    /// Your changes to the checkmarks, by item key, for this session.
    private var overrides: [String: Bool] = [:]
    init(preferences: Preferences) { self.preferences = preferences }
    // Checking and unchecking reuse the last scan; stopping something clears it.

    func load(_ filter: String) async throws -> [LauncherResult] {
        let items: [Cleanup.Item]
        if let cache, Date().timeIntervalSince(cache.at) < 30 { items = cache.items }
        else { items = await Cleanup.scan(ignored: Set(preferences.cleanupIgnored)); cache = (Date(), items) }
        guard !items.isEmpty else { throw SourceProblem(text: "Nothing to clean up. No idle servers, leftover processes, or simulators are running.") }
        let checked = items.filter { overrides[$0.id] ?? $0.finding.checked }
        let freed = checked.map(\.finding.memoryMB).reduce(0, +)
        let run = Verb(title: "Clean Up", after: .stay) { [weak self] in
            guard let self else { return nil }
            var done: [String] = []
            let before = Cleanup.availableMB()
            for item in checked { done.append(await Cleanup.stop(item)) }
            self.overrides = [:]; self.cache = nil
            // Memory comes back over a few seconds as processes exit.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let gained = Cleanup.availableMB() - before
            return done.isEmpty ? "Nothing was checked." : done.joined(separator: " · ") + (gained > 50 ? " · \(Cleanup.size(gained)) more memory free" : "")
        }
        var rows = [LauncherResult(id: "cleanup:run", title: checked.isEmpty ? "Nothing checked" : "Clean Up \(checked.count) item" + (checked.count == 1 ? "" : "s"),
                                   detail: checked.isEmpty ? "Return on an item checks it" : "Uses up to \(Cleanup.size(freed)) · T3 Code, Chrome, and apps in front keep running",
                                   symbol: "leaf", action: .thing(Thing(verbs: checked.isEmpty ? [] : [run], twoLine: false)), score: 5000)]
        rows += items.enumerated().map { index, item in
            let on = overrides[item.id] ?? item.finding.checked
            let toggle = Verb(title: on ? "Leave Running" : "Include", after: .stay) { [weak self] in
                self?.overrides[item.id] = !on; return nil
            }
            let now = Verb(title: "Stop Now", after: .stay) { [weak self] in
                let result = await Cleanup.stop(item); self?.cache = nil; return result
            }
            let ignore = Verb(title: "Always Ignore", after: .stay) { [weak self] in
                self?.preferences.cleanupIgnored.append(item.id); self?.cache = nil
                return "\(item.finding.title) will not be offered again. Settings › Search lists ignored items."
            }
            return LauncherResult(id: "cleanup:" + item.id, title: item.finding.title,
                                  detail: [item.finding.group.title, Cleanup.size(item.finding.memoryMB), item.finding.detail].joined(separator: " · "),
                                  symbol: on ? "checkmark.circle.fill" : "circle", action: .thing(Thing(verbs: [toggle, now, ignore])), score: 4000 - Double(index))
        }
        return rows
    }
}
