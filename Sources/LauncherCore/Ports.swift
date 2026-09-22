import Foundation

/// A process that listens on a local TCP port.
public struct ListeningPort: Identifiable, Sendable, Equatable, Hashable {
    public let pid: Int32
    public let command: String
    public let port: Int
    /// True when it listens on every interface ("*:3000"), so other devices on the network can reach it.
    public var exposed: Bool
    public var id: String { "port:\(port):\(pid)" }
    public init(pid: Int32, command: String, port: Int, exposed: Bool = false) {
        self.pid = pid; self.command = command; self.port = port; self.exposed = exposed
    }
}

/// Reads port queries such as "port 3000", "kill port 3000", "kill 3000", ":3000", and "ports".
public struct PortQuery: Equatable, Sendable {
    /// The port to find, or nil to list every listening port.
    public let port: Int?
    public init(port: Int?) { self.port = port }

    public static func parse(_ text: String) -> PortQuery? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        if words.count == 1, first.hasPrefix(":"), let port = number(String(first.dropFirst())) { return PortQuery(port: port) }
        if ["port", "ports"].contains(first) {
            if words.count == 1 { return PortQuery(port: nil) }
            if words.count == 2, let port = number(words[1]) { return PortQuery(port: port) }
            return nil
        }
        if ["kill", "stop", "free"].contains(first), words.count >= 2 {
            if ["port", "ports"].contains(words[1]) {
                if words.count == 2 { return PortQuery(port: nil) }
                if words.count == 3, let port = number(words[2]) { return PortQuery(port: port) }
                return nil
            }
            if words.count == 2, let port = number(words[1].hasPrefix(":") ? String(words[1].dropFirst()) : words[1]) {
                return PortQuery(port: port)
            }
        }
        // "stop whatever is running on 3000", "what's on port 5173", "kill the server on localhost:8080".
        let portWords: Set<String> = ["port", "running", "listening", "server", "localhost", "dev"]
        if words.contains(where: { portWords.contains($0) || $0.hasPrefix("localhost:") }) {
            // The number must read as a port: "on 3000", "port 3000", "at 3000", ":3000", or "localhost:3000".
            for (index, word) in words.enumerated() {
                let tail = word.split(separator: ":").last.map(String.init) ?? word
                guard let port = number(tail) else { continue }
                if word.contains(":") || (index > 0 && ["on", "port", "at"].contains(words[index - 1])) { return PortQuery(port: port) }
            }
        }
        return nil
    }

    /// The first valid port number anywhere in free text, for a request Jev matched to ports.
    public static func firstPort(in text: String) -> Int? {
        text.split(whereSeparator: { !$0.isNumber }).lazy.compactMap { number(String($0)) }.first
    }

    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text), (1...65_535).contains(value) else { return nil }
        return value
    }
}

public enum ListeningPorts {
    /// Fixed arguments for `/usr/sbin/lsof`: numeric output, TCP listeners only, machine-readable fields.
    public static let lsofArguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]

    /// Parses `lsof -Fpcn` output. One entry per process and port, sorted by port.
    /// A port counts as exposed when any of its addresses is not loopback.
    public static func parse(_ output: String) -> [ListeningPort] {
        var found: [String: ListeningPort] = [:]
        var pid: Int32?
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = ""
            case "c": command = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = String(value[..<colon])
                let exposed = !["127.0.0.1", "[::1]", "localhost"].contains(host)
                var entry = found["\(pid):\(port)"] ?? ListeningPort(pid: pid, command: command, port: port)
                entry.exposed = entry.exposed || exposed
                found["\(pid):\(port)"] = entry
            default: continue
            }
        }
        return found.values.sorted { $0.port != $1.port ? $0.port < $1.port : $0.pid < $1.pid }
    }
}

/// What `ps` and `lsof` say about one process, for the port list. Read on this Mac only.
public struct ProcessSnapshot: Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32 = 0
    /// Percent of one core, as `ps` reports it.
    public var cpu: Double = 0
    /// Resident memory in kilobytes.
    public var residentKB: Int = 0
    /// Seconds since the process started.
    public var uptime: Int = 0
    /// Full path of the executable.
    public var executable: String = ""
    /// The command line, such as "node /Users/me/site/node_modules/.bin/vite --port 5173".
    public var arguments: String = ""
    /// The working folder, often the project the server belongs to.
    public var folder: String?

    public init(pid: Int32) { self.pid = pid }

    public enum Owner: Equatable, Sendable {
        /// Yours, and not part of macOS: safe to stop.
        case yours
        /// A macOS service such as AirPlay Receiver. Stopping it can work, but macOS starts it again.
        case system
        /// Another user, such as root. Stopping it needs an administrator.
        case otherUser
    }

    public func owner(currentUID: UInt32) -> Owner {
        if uid != currentUID { return .otherUser }
        let systemRoots = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/Library/Apple/"]
        return systemRoots.contains(where: executable.hasPrefix) ? .system : .yours
    }

    /// "84 MB", "1.2 GB".
    public var memoryText: String {
        let mb = Double(residentKB) / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    /// "0.4% CPU", "112% CPU" (more than one core).
    public var cpuText: String { String(format: cpu < 10 ? "%.1f%% CPU" : "%.0f%% CPU", cpu) }

    /// "up 45 s", "up 12 min", "up 3 h", "up 2 d".
    public var uptimeText: String {
        switch uptime {
        case ..<60: return "up \(uptime) s"
        case ..<3600: return "up \(uptime / 60) min"
        case ..<86_400: return "up \(uptime / 3600) h"
        default: return "up \(uptime / 86_400) d"
        }
    }

    /// A short name for what the process is serving: "vite", "next dev", "http.server", "postgres".
    public var role: String {
        // The executable path can contain spaces, so it is removed from the command line as a whole.
        let restText = !executable.isEmpty && arguments.hasPrefix(executable)
            ? String(arguments.dropFirst(executable.count))
            : arguments.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let tool = executable.isEmpty
            ? ((arguments.split(separator: " ").first.map(String.init) ?? "") as NSString).lastPathComponent
            : (executable as NSString).lastPathComponent
        guard !tool.isEmpty else { return "" }
        let parts = [tool] + restText.split(separator: " ").map(String.init)
        let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "java", "php", "npx", "pnpm", "yarn", "npm"]
        let lower = tool.lowercased()
        guard interpreters.contains(lower) || lower.hasPrefix("python") else { return tool }
        // The script or module after the interpreter tells what it is.
        var index = 1
        while index < parts.count {
            let part = parts[index]
            if part == "-m", index + 1 < parts.count { return parts[index + 1] }
            if part.hasPrefix("-") || ["run", "exec", "x"].contains(part) { index += 1; continue }
            let name = (part as NSString).lastPathComponent
            // "next dev", "nuxt dev", "astro dev": the subcommand matters.
            if ["next", "nuxt", "astro", "remix"].contains(name), index + 1 < parts.count, !parts[index + 1].hasPrefix("-") {
                return name + " " + parts[index + 1]
            }
            return name
        }
        return tool
    }
}

public enum ProcessSnapshots {
    /// Fixed `ps` arguments for numbers that never contain spaces.
    public static func statsArguments(_ pids: [Int32]) -> [String] {
        ["-o", "pid=,uid=,%cpu=,rss=,etime=", "-p", pids.map(String.init).joined(separator: ",")]
    }
    public static func executableArguments(_ pids: [Int32]) -> [String] {
        ["-o", "pid=,comm=", "-p", pids.map(String.init).joined(separator: ",")]
    }
    public static func commandLineArguments(_ pids: [Int32]) -> [String] {
        ["-ww", "-o", "pid=,args=", "-p", pids.map(String.init).joined(separator: ",")]
    }
    /// `lsof` arguments for each process's working folder.
    public static func folderArguments(_ pids: [Int32]) -> [String] {
        ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")]
    }

    /// Joins the outputs of the calls above into one snapshot per PID.
    public static func parse(stats: String, executables: String, commandLines: String, folders: String) -> [Int32: ProcessSnapshot] {
        var result: [Int32: ProcessSnapshot] = [:]
        for line in stats.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 5, let pid = Int32(fields[0]) else { continue }
            var snapshot = ProcessSnapshot(pid: pid)
            snapshot.uid = UInt32(fields[1]) ?? 0
            snapshot.cpu = Double(fields[2].replacingOccurrences(of: ",", with: ".")) ?? 0
            snapshot.residentKB = Int(fields[3]) ?? 0
            snapshot.uptime = elapsedSeconds(fields[4])
            result[pid] = snapshot
        }
        for (pid, text) in pidLines(executables) { result[pid]?.executable = text }
        for (pid, text) in pidLines(commandLines) { result[pid]?.arguments = text }
        var pid: Int32?
        for line in folders.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" { pid = Int32(value) } else if tag == "n", let pid, value != "/" { result[pid]?.folder = value }
        }
        return result
    }

    /// `ps` elapsed time "[[dd-]hh:]mm:ss" in seconds.
    public static func elapsedSeconds(_ text: String) -> Int {
        let dayParts = text.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        let seconds = clock.reversed().enumerated().reduce(0) { total, item in total + item.element * [1, 60, 3600][min(item.offset, 2)] }
        return days * 86_400 + seconds
    }

    /// Lines of "  pid rest of line" split into the PID and the rest, which may contain spaces.
    private static func pidLines(_ output: String) -> [(Int32, String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { return nil }
            return (pid, trimmed[space...].trimmingCharacters(in: .whitespaces))
        }
    }
}
