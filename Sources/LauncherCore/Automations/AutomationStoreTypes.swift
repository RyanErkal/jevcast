import Foundation

/// `Automations/<id>/state.json`. Written by the runner.
public struct AutomationState: Codable, Equatable, Sendable {
    /// The newest scheduled occurrence already run or skipped.
    public var lastCovered: Date?
    public var lastRunID: String?
    public init(lastCovered: Date? = nil, lastRunID: String? = nil) { self.lastCovered = lastCovered; self.lastRunID = lastRunID }
}

/// `Automations/runner.json`. The runner rewrites it every 30 seconds so the app can show it is alive.
public struct RunnerHeartbeat: Codable, Equatable, Sendable {
    public var pid: Int32
    public var started: Date
    public var heartbeat: Date
    public var version: String
    /// True when the runner binary carries a non-ad-hoc code signature.
    public var signedBuild: Bool
    public init(pid: Int32, started: Date, heartbeat: Date, version: String, signedBuild: Bool) {
        self.pid = pid; self.started = started; self.heartbeat = heartbeat; self.version = version; self.signedBuild = signedBuild
    }
    /// Alive when the last beat is under 90 seconds old.
    public func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(heartbeat) < 90 }
}

public enum AutomationStoreError: Error, Equatable, CustomStringConvertible {
    case invalidID(String)
    case symlink(String)
    case notOwned(String)
    case tooLarge(String)
    case notRegularFile(String)
    case io(String)
    public var description: String {
        switch self {
        case .invalidID(let s): return "Invalid ID: \(s)"
        case .symlink(let s): return "Refused a symbolic link: \(s)"
        case .notOwned(let s): return "Not owned by this user: \(s)"
        case .tooLarge(let s): return "File too large: \(s)"
        case .notRegularFile(let s): return "Not a regular file: \(s)"
        case .io(let s): return s
        }
    }
}

/// Shared JSON coding for automation files. Dates are stored as seconds since 2001-01-01 (Foundation's
/// reference date), which round-trips exactly, so a stored occurrence always equals the computed one.
public enum AutomationJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .deferredToDate
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }
}
