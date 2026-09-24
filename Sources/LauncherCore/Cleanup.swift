import Foundation

/// One process from `ps`.
public struct CleanupProcess: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let cpu: Double
    public let memoryMB: Double
    /// Seconds since it started.
    public let elapsed: TimeInterval
    public let path: String
    public init(pid: Int32, ppid: Int32, uid: UInt32, cpu: Double, memoryMB: Double, elapsed: TimeInterval, path: String) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.cpu = cpu; self.memoryMB = memoryMB; self.elapsed = elapsed; self.path = path
    }
    public var name: String { (path as NSString).lastPathComponent }

    /// Arguments for `ps`: the command comes last because its path may contain spaces.
    public static let psArguments = ["-Ao", "pid=,ppid=,uid=,%cpu=,rss=,etime=,comm="]

    public static func parse(_ output: String) -> [CleanupProcess] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 7, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let uid = UInt32(fields[2]),
                  let cpu = Double(fields[3]), let rss = Double(fields[4]), let elapsed = parseElapsed(fields[5]) else { return nil }
            return CleanupProcess(pid: pid, ppid: ppid, uid: uid, cpu: cpu, memoryMB: rss / 1024, elapsed: elapsed, path: fields[6])
        }
    }

    /// `ps` elapsed time: "[[dd-]hh:]mm:ss".
    public static func parseElapsed(_ text: String) -> TimeInterval? {
        var days = 0.0, rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d; rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.map { $0! }
        let seconds = values.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86_400 + seconds
    }
}

/// Something the cleanup list offers to stop, and whether it is checked at first.
public struct CleanupFinding: Equatable, Sendable {
    public enum Group: String, Sendable, CaseIterable {
        case simulator, server, orphan, docker, idleApp, heavy
        public var title: String {
            switch self {
            case .simulator: return "Simulator"
            case .server: return "Idle dev server"
            case .orphan: return "Leftover process"
            case .docker: return "Docker"
            case .idleApp: return "Idle app"
            case .heavy: return "Heavy process"
            }
        }
    }
    public let group: Group
    /// Stable across runs, for "Always Ignore": such as "server:node:3000".
    public let key: String
    public let title: String
    public let detail: String
    public let pids: [Int32]
    public let memoryMB: Double
    public let checked: Bool
    public init(group: Group, key: String, title: String, detail: String, pids: [Int32], memoryMB: Double, checked: Bool) {
        self.group = group; self.key = key; self.title = title; self.detail = detail; self.pids = pids; self.memoryMB = memoryMB; self.checked = checked
    }
}

/// Finds idle dev servers, leftover dev processes, and heavy processes. It never offers a system
/// process, another user's process, anything launchd manages, or anything a protected app started.
public enum CleanupRules {
    /// Programs that dev servers, watchers, and build tools run as.
    static let devNames: [String] = ["node", "bun", "deno", "python", "ruby", "php", "java", "go", "vite", "esbuild", "tsc",
                                     "npm", "npx", "pnpm", "yarn", "turbo", "next-server", "uvicorn", "gunicorn", "watchman", "cargo", "air"]
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Applications/Xcode.app/", "/Library/Developer/CoreSimulator/"]

    public static func isDevTool(_ process: CleanupProcess) -> Bool {
        let name = process.name.lowercased()
        return devNames.contains { name == $0 || name.hasPrefix($0 + "3") || name.hasPrefix($0 + "@") || (($0 == "python") && name.hasPrefix("python")) }
    }

    public static func isSystem(_ process: CleanupProcess) -> Bool {
        systemPrefixes.contains { process.path.hasPrefix($0) } || process.path.contains("/RuntimeRoot/")
    }

    /// True when the process or any process above it is one of `roots`.
    public static func descends(_ pid: Int32, from roots: Set<Int32>, parents: [Int32: Int32]) -> Bool {
        var current = pid, steps = 0
        while current > 1, steps < 64 {
            if roots.contains(current) { return true }
            guard let parent = parents[current] else { return false }
            current = parent; steps += 1
        }
        return false
    }

    public struct Input: Sendable {
        public var processes: [CleanupProcess]
        public var uid: UInt32
        /// PIDs of processes listening on a TCP port, and the ports.
        public var listening: [Int32: [Int]]
        /// PIDs launchd runs for a job, such as the user's own agents. Never offered.
        public var launchdPIDs: Set<Int32>
        /// PIDs of protected apps, such as T3 Code and Chrome. Their whole tree is kept.
        public var protectedRoots: Set<Int32>
        public var ignoredKeys: Set<String>
        public init(processes: [CleanupProcess], uid: UInt32, listening: [Int32: [Int]], launchdPIDs: Set<Int32>,
                    protectedRoots: Set<Int32>, ignoredKeys: Set<String>) {
            self.processes = processes; self.uid = uid; self.listening = listening; self.launchdPIDs = launchdPIDs
            self.protectedRoots = protectedRoots; self.ignoredKeys = ignoredKeys
        }
    }

    public static func find(_ input: Input) -> [CleanupFinding] {
        let parents = Dictionary(input.processes.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [CleanupProcess]] = [:]
        for process in input.processes { children[process.ppid, default: []].append(process) }
        func tree(_ root: CleanupProcess) -> [CleanupProcess] {
            var all = [root], queue = [root.pid], seen: Set<Int32> = [root.pid]
            while let next = queue.popLast() {
                for child in children[next] ?? [] where seen.insert(child.pid).inserted { all.append(child); queue.append(child.pid) }
            }
            return all
        }
        let mine = input.processes.filter { $0.uid == input.uid && $0.pid > 1 && !isSystem($0) }
        let kept: (CleanupProcess) -> Bool = { process in
            input.launchdPIDs.contains(process.pid) || descends(process.pid, from: input.protectedRoots, parents: parents)
        }
        var findings: [CleanupFinding] = []
        var taken = Set<Int32>()
        func add(_ finding: CleanupFinding) {
            guard !input.ignoredKeys.contains(finding.key), !finding.pids.contains(where: taken.contains) else { return }
            taken.formUnion(finding.pids)
            findings.append(finding)
        }
        // Idle dev servers: listening for an hour or more, and quiet now.
        for process in mine where isDevTool(process) && !kept(process) {
            guard let ports = input.listening[process.pid], process.elapsed >= 3600, process.cpu < 1 else { continue }
            let family = tree(process)
            let memory = family.map(\.memoryMB).reduce(0, +)
            add(CleanupFinding(group: .server, key: "server:\(process.name):\(ports.sorted().map(String.init).joined(separator: ","))",
                               title: "\(process.name) on :" + ports.sorted().map(String.init).joined(separator: ", :"),
                               detail: "Up \(duration(process.elapsed)) · idle", pids: family.map(\.pid), memoryMB: memory, checked: true))
        }
        // Leftovers: dev tools whose parent is gone, not serving, over two hours old, and quiet.
        for process in mine where isDevTool(process) && !kept(process) && process.ppid == 1 && input.listening[process.pid] == nil {
            guard process.elapsed >= 7200, process.cpu < 1 else { continue }
            let family = tree(process)
            add(CleanupFinding(group: .orphan, key: "orphan:\(process.name)", title: process.name,
                               detail: "Started \(duration(process.elapsed)) ago · no parent app · idle",
                               pids: family.map(\.pid), memoryMB: family.map(\.memoryMB).reduce(0, +), checked: true))
        }
        // Heavy: shown for you to decide, never checked.
        for process in mine where process.cpu >= 30 && !kept(process) {
            add(CleanupFinding(group: .heavy, key: "heavy:\(process.name)", title: process.name,
                               detail: String(format: "%.0f%% CPU now · up ", process.cpu) + duration(process.elapsed),
                               pids: [process.pid], memoryMB: process.memoryMB, checked: false))
        }
        return findings
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 { return "\(Int(seconds / 86_400)) d" }
        if seconds >= 3600 { return "\(Int(seconds / 3600)) h" }
        return "\(max(1, Int(seconds / 60))) min"
    }

    /// Booted simulators from `xcrun simctl list devices booted -j`: name and UDID.
    public static func bootedSimulators(_ json: Data) -> [(name: String, udid: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.values.flatMap { $0 }.compactMap { device in
            guard (device["state"] as? String) == "Booted", let name = device["name"] as? String, let udid = device["udid"] as? String else { return nil }
            return (name, udid)
        }.sorted { $0.name < $1.name }
    }
}
