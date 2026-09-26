import Foundation

/// The double-run guard for automations imported from Codex: while the Codex original is ACTIVE,
/// or cannot be read, the Jevcast copy must not run. Reads only the top-level `status` key.
public enum CodexSourceGuard {
    public enum Verdict: Equatable, Sendable {
        case clear
        case blocked(String)
    }

    public static func check(_ automation: Automation) -> Verdict {
        guard let source = automation.source, source.app == .codex else { return .clear }
        return check(path: source.path)
    }

    public static func check(path: String) -> Verdict {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? SecureFile.read(URL(fileURLWithPath: expanded), maxBytes: 512 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return .blocked("The Codex original could not be read, so this copy will not run. Pause it in Codex and check the path.")
        }
        guard let status = topLevelStatus(text) else {
            return .blocked("The Codex original has no status, so this copy will not run.")
        }
        if status.uppercased() == "ACTIVE" {
            return .blocked("The Codex original is still ACTIVE. Pause it in Codex first so the work does not run twice.")
        }
        guard status.uppercased() == "PAUSED" else {
            return .blocked("The Codex original has an unknown status, so this copy will not run.")
        }
        return .clear
    }

    /// The value of `status = "..."` before the first table header.
    static func topLevelStatus(_ text: String) -> String? {
        guard let table = try? TomlLite.parse(text), case .string(let status)? = table["status"] else { return nil }
        return status
    }
}
