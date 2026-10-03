import Foundation

/// The models offered for each provider. Stored values are model IDs.
/// An empty stored ID means the provider default. An unknown stored ID is kept as is.
public enum AgentModelCatalog {
    public struct Choice: Hashable, Sendable {
        public let id: String
        public let name: String
    }

    public static func choices(_ runner: AgentRunner) -> [Choice] {
        switch runner {
        case .codex:
            return [Choice(id: "gpt-6-luna", name: "GPT-6 Luna"), Choice(id: "gpt-6-sol", name: "GPT-6 Sol"),
                    Choice(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"), Choice(id: "gpt-6-astra", name: "GPT-6 Astra")]
        case .claude:
            return [Choice(id: "claude-opus-5-5", name: "Opus 5.5")]
        }
    }

    public static func defaultModel(_ runner: AgentRunner) -> String { choices(runner)[0].id }

    /// Effort levels offered in pickers. `none` is not offered.
    public static let efforts: [ReasoningEffort] = [.low, .medium, .high, .xhigh, .max]

    /// Only Codex has a faster service tier.
    public static func supportsFast(_ runner: AgentRunner) -> Bool { runner == .codex }

    /// The ID sent to the CLI: the stored ID, or the provider default when empty.
    public static func resolved(_ id: String, runner: AgentRunner) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultModel(runner) : trimmed
    }

    public static func isKnown(_ id: String, runner: AgentRunner) -> Bool {
        choices(runner).contains { $0.id == id }
    }

    /// "GPT-6 Luna" for a known ID, "Custom: <id>" for an unknown one.
    public static func displayName(_ id: String, runner: AgentRunner) -> String {
        let r = resolved(id, runner: runner)
        return choices(runner).first { $0.id.caseInsensitiveCompare(r) == .orderedSame }?.name ?? "Custom: " + r
    }

    /// "ChatGPT (Codex) · GPT-6 Luna · High · Normal".
    public static func summary(_ task: AgentTask) -> String {
        let speed = supportsFast(task.runner) && task.fast ? "Fast" : "Normal"
        return [task.runner.title, displayName(task.model, runner: task.runner), task.effort.title, speed].joined(separator: " · ")
    }
}
