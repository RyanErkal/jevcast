import AppKit
import LauncherCore

/// "cleanup" or "cool down": a checklist of background work to stop, such as simulators nobody
/// is looking at, idle dev servers, and leftover dev processes. Manual only: nothing stops until
/// you press Return on the Clean Up row. Protected apps and everything they started stay running.
@MainActor
enum Cleanup {
    /// Apps whose whole process tree is always kept, such as your editor and browser.
    static let protectedApps = ["com.t3tools.t3code", "com.google.Chrome", "com.openai.codex", "com.openai.chat", "com.apple.finder",
                                "com.apple.mail", "com.apple.Terminal", "com.mitchellh.ghostty"]

    struct Item: Identifiable {
        let finding: CleanupFinding
        /// Simulator UDIDs to shut down, or an app to quit, instead of PIDs to stop.
        var simulators: [String] = []
        var app: NSRunningApplication?
        var identities: [CleanupIdentity] = []
        var id: String { finding.key }
    }

    /// Reads the Mac. Runs off the main thread except for the running-apps list.
    static func scan(ignored: Set<String>) async -> [Item] {
        let apps = NSWorkspace.shared.runningApplications
        async let simJSON = try? CommandRunner.capture(["/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j"], allowFailure: true, timeout: 20)
        var input: CleanupRules.Input
        do { input = try await processInput() }
        catch {
            return [Item(finding: CleanupFinding(group: .computerUse, key: "scan-unavailable", title: "Process Scan Unavailable",
                                                detail: "Ownership could not be checked; nothing will be stopped. Try again.",
                                                pids: [], memoryMB: 0, checked: false, canStop: false))]
        }
        input.ignoredKeys = ignored
        let processes = input.processes

        var items: [Item] = []
        // An agent session may use a device even when xcodebuild has already ended.
        let booted = CleanupRules.bootedSimulators(Data((await simJSON ?? "").utf8))
        if !booted.isEmpty, !ignored.contains("simulators") {
            let testing = processes.contains { $0.name == "xcodebuild" || (ComputerUseCleanup.isAgentHost($0) && $0.name != "jevcast-runner") }
            let memory = processes.filter { $0.path.contains("/RuntimeRoot/") || $0.name.hasSuffix("_sim") }.map(\.memoryMB).reduce(0, +)
            let names = booted.map(\.name)
            let detail = (names.count <= 3 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more")
                + (testing ? " · coding or device tools are running, so these may be in use" : "")
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
        let findings = CleanupRules.find(input)
        items += findings.map { finding in
            Item(finding: finding, identities: finding.pids.compactMap { pid in processes.first { $0.pid == pid }?.identity })
        }
        return items
    }

    private static var stopping = false

    /// Rechecks the selection before TERM. Only disconnected computer-use workers may receive KILL.
    static func stop(_ item: Item) async -> String {
        guard item.finding.canStop else { return item.finding.title + " left running: protected" }
        guard !stopping else { return "Clean Up is already running." }
        stopping = true
        defer { stopping = false }
        if !item.simulators.isEmpty {
            for udid in item.simulators { _ = try? await CommandRunner.capture(["/usr/bin/xcrun", "simctl", "shutdown", udid], allowFailure: true, timeout: 60) }
            // Simulator.app itself holds memory once its devices are off.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").forEach { $0.terminate() }
            return item.finding.title + " shut down"
        }
        if let app = item.app { app.terminate(); return item.finding.title + " quit" }
        let plan = CleanupStopPlan(finding: item.finding, identities: item.identities)
        do {
            let input = try await processInput()
            guard let targets = plan.validate(input) else { return item.finding.title + " left running: the process or its work changed; rescan" }
            if targets.isEmpty { return item.finding.title + " already ended" }
            // Children first: a still-live worker cannot lose its parent between identity checks.
            var failed = false
            for identity in targets.reversed() {
                if !CleanupStopPlan.signal(identity) { failed = true; break }
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            var current = try await processInput()
            guard let remaining = plan.validate(current, afterTermination: true) else {
                return item.finding.title + " changed after the stop request; remaining processes left running"
            }
            if item.finding.group == .computerUse, !remaining.isEmpty, !failed {
                for identity in remaining.reversed() {
                    if !CleanupStopPlan.signal(identity, force: true) { failed = true; break }
                }
                try await Task.sleep(nanoseconds: 500_000_000)
                current = try await processInput()
            }
            guard let alive = plan.validate(current, afterTermination: true) else {
                return item.finding.title + " could not be verified; remaining processes left running"
            }
            guard alive.isEmpty else { return "\(item.finding.title): \(alive.count) process(es) still running; rescan" }
            let restarted = item.finding.group == .computerUse && current.processes.contains { process in
                guard let original = input.processes.first(where: { $0.pid == item.finding.pids.first }) else { return false }
                return ComputerUseCleanup.kind(process, home: current.homeDirectory) == ComputerUseCleanup.kind(original, home: input.homeDirectory)
                    && !item.finding.pids.contains(process.pid)
            }
            return item.finding.title + " stopped" + (restarted ? "; other workers remain running" : "")
        } catch {
            return item.finding.title + " could not be verified; rescan before trying again"
        }
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
