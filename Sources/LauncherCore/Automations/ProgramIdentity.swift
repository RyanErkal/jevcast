import CryptoKit
import Darwin
import Foundation

/// What a program file looked like when the user approved it: size, modification time, and for
/// scripts the SHA-256 of its bytes (skipped above `maxHashBytes`, where size and time stand in).
public struct ProgramIdentity: Codable, Equatable, Sendable {
    public static let maxHashBytes: UInt64 = 200 * 1024 * 1024

    public var path: String
    public var size: UInt64
    public var modified: Date
    /// Lowercase hex. Nil for agent CLIs and for files over `maxHashBytes`.
    public var sha256: String?

    public init(path: String, size: UInt64, modified: Date, sha256: String? = nil) {
        self.path = path; self.size = size; self.modified = modified; self.sha256 = sha256
    }

    /// Reads a program file, following links as `posix_spawn` does. Nil when it cannot be read.
    public static func read(path: String, hash: Bool) -> ProgramIdentity? {
        guard !path.isEmpty else { return nil }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        let size = UInt64(max(0, st.st_size))
        let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        var digest: String?
        if hash, size <= maxHashBytes {
            guard let d = sha256(fd) else { return nil }
            digest = d
        }
        return ProgramIdentity(path: path, size: size, modified: modified, sha256: digest)
    }

    /// True when `current` is the approved program. With a hash, the bytes decide; without one, size and time.
    public func matches(_ current: ProgramIdentity?) -> Bool {
        guard let current, current.path == path, current.size == size else { return false }
        if let sha256 { return current.sha256 == sha256 }
        return abs(current.modified.timeIntervalSince(modified)) < 0.000_01
    }

    private static func sha256(_ fd: Int32) -> String? {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total: UInt64 = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n < 0 { return nil }
            if n == 0 { break }
            total += UInt64(n)
            if total > maxHashBytes { return nil }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension Automation {
    /// The script program for script kinds and the preflight of a report workflow, nil for agents.
    public var scriptTask: ScriptTask? {
        switch kind {
        case .script(let s), .scriptWithDiagnosis(let s, _): return s
        case .staged(let t): return t.preflight
        case .agent: return nil
        }
    }

    public var agentTask: AgentTask? {
        switch kind {
        case .agent(let t), .scriptWithDiagnosis(_, let t): return t
        case .staged(let t): return t.analyst
        case .script: return nil
        }
    }

    /// Records what the user approves by saving: the script's bytes, the script files it runs, and the agent
    /// CLI's size and time. Call on every save. `settings` gives the CLI paths the runner will use.
    public mutating func recordApprovedPrograms(settings: AutomationSettings) {
        approvedProgram = scriptTask.flatMap { ProgramIdentity.read(path: $0.executable, hash: true) }
        approvedAgentCLI = agentTask.flatMap {
            ProgramIdentity.read(path: $0.runner == .codex ? settings.codexPath : settings.claudePath, hash: false)
        }
        let files = approvalFiles
        approvedFiles = files.isEmpty ? nil : files.compactMap { ProgramIdentity.read(path: $0, hash: true) }
    }

    /// Every file the runner checks before it starts a stage: script files in the arguments, the other
    /// stage programs, and the files the definition pins.
    public var approvalFiles: [String] {
        var paths: [String] = []
        switch kind {
        case .script(let s), .scriptWithDiagnosis(let s, _):
            paths = ProgramIdentity.scriptFiles(s.arguments, in: s.workingDirectory)
        case .staged(let t):
            for script in t.scripts {
                if script.executable != t.preflight.executable { paths.append(script.executable) }
                paths += ProgramIdentity.scriptFiles(script.arguments, in: script.workingDirectory)
            }
            if let fetch = t.fetch, let program = fetch.command.first {
                paths.append(program)
                paths += ProgramIdentity.scriptFiles(Array(fetch.command.dropFirst()), in: fetch.commandDirectory)
            }
        case .agent: break
        }
        paths += pinnedFiles ?? []
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

extension ProgramIdentity {
    static let scriptExtensions: Set<String> = ["ts", "tsx", "js", "mjs", "cjs", "py", "sh", "zsh", "bash", "rb", "pl", "swift"]

    /// Arguments that name an existing script file, as full paths. Relative names resolve in `folder`.
    public static func scriptFiles(_ arguments: [String], in folder: String) -> [String] {
        var found: [String] = []
        for argument in arguments where !argument.hasPrefix("-") && !argument.isEmpty {
            let path = argument.hasPrefix("/") ? argument : URL(fileURLWithPath: folder).appendingPathComponent(argument).standardized.path
            guard scriptExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            found.append(path)
        }
        return found
    }
}
