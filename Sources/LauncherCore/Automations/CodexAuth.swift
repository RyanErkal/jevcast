import Foundation

/// Checks, before a Codex run, that the CLI signs in with a ChatGPT subscription and not an API key,
/// so a run never moves to API billing without the user knowing. Reads `~/.codex/auth.json` only;
/// never writes it and never shows its values.
public enum CodexAuth {
    public enum Status: Equatable, Sendable {
        case subscription
        case problem(String)
    }

    public static func authFile(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")
    }

    public static func check(home: String) -> Status {
        let url = authFile(home: home)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .problem("Codex is not signed in on this Mac. Run `codex login` with your ChatGPT account, then try again.")
        }
        guard (attributes[.size] as? Int ?? 0) < 1_000_000, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .problem("Codex's sign-in file could not be read, so the run did not start.")
        }
        return status(root)
    }

    /// The decision for a parsed `auth.json`.
    public static func status(_ root: [String: Any]) -> Status {
        if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return .problem("Codex is signed in with an API key, which bills the API account. Jevcast runs Codex only with a ChatGPT sign-in. Run `codex logout`, then `codex login` with ChatGPT.")
        }
        if let mode = root["auth_mode"] as? String, !mode.lowercased().hasPrefix("chatgpt") {
            return .problem("Codex uses the \(mode.prefix(40)) sign-in. Jevcast runs Codex only with a ChatGPT sign-in.")
        }
        guard let tokens = root["tokens"] as? [String: Any],
              [tokens["access_token"], tokens["refresh_token"]].contains(where: { ($0 as? String).map { !$0.isEmpty } ?? false }) else {
            return .problem("Codex has no ChatGPT sign-in. Run `codex login` with your ChatGPT account, then try again.")
        }
        return .subscription
    }
}
