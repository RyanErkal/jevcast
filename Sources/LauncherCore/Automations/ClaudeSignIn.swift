import Foundation

/// Claude Code can sign in through a gateway set as `env` in `~/.claude/settings.json`.
/// `--restricted` ignores that file, so the runner copies only the sign-in values into a
/// short-lived 0600 file in the run folder and passes it with `--settings`. Nothing else is copied.
public enum ClaudeSignIn {
    public static let keys: Set<String> = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"]
    public static let fileName = "claude-settings.json"

    public static func settingsURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
    }

    /// The sign-in values, or nil when the user's settings set no gateway.
    public static func gatewayEnvironment(settings url: URL = settingsURL()) -> [String: String]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? 0) < 1_000_000,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return nil }
        var found: [String: String] = [:]
        for key in keys { if let value = env[key] as? String, !value.isEmpty { found[key] = value } }
        return found["ANTHROPIC_BASE_URL"] == nil ? nil : found
    }

    /// The `--settings` file body.
    public static func settingsData(_ env: [String: String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["env": env], options: [.sortedKeys])
    }
}
