import Foundation

/// Reads the JSON lines a CLI prints (Codex `--json`, Claude `stream-json`). Unknown events are ignored.
public struct RunnerEvents: Sendable {
    public static let maxLineBytes = 1024 * 1024
    public static let maxActivity = 40

    public let runner: AgentRunner
    public private(set) var sessionID: String?
    public private(set) var usage: TokenUsage?
    /// The agent's final message text.
    public private(set) var finalText: String?
    /// The final structured reply, as JSON object bytes.
    public private(set) var structured: Data?
    public private(set) var error: String?
    /// Short lines for the run view: "Ran: ls -la", "Read file".
    public private(set) var activity: [String] = []
    public private(set) var skippedLines = 0

    public init(runner: AgentRunner) { self.runner = runner }

    public mutating func consume(_ line: Data) {
        guard line.count <= Self.maxLineBytes else { skippedLines += 1; return }
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = o["type"] as? String else { return }
        switch runner {
        case .codex: codex(type, o)
        case .claude: claude(type, o)
        }
    }

    public mutating func consume(_ line: String) { consume(Data(line.utf8)) }

    private mutating func codex(_ type: String, _ o: [String: Any]) {
        switch type {
        case "thread.started": sessionID = o["thread_id"] as? String ?? sessionID
        case "item.started", "item.completed":
            guard let item = o["item"] as? [String: Any], let kind = item["type"] as? String else { return }
            switch (type, kind) {
            case ("item.completed", "agent_message"):
                if let text = item["text"] as? String { setFinal(text) }
            case ("item.started", "command_execution"):
                if let cmd = item["command"] as? String { note("Ran: " + oneLine(cmd, 80)) }
            case ("item.completed", "command_execution"):
                if activity.last?.hasPrefix("Ran: ") != true, let cmd = item["command"] as? String { note("Ran: " + oneLine(cmd, 80)) }
            case ("item.completed", "file_change"): note("Changed files")
            case ("item.completed", "web_search"): note("Searched the web")
            case ("item.completed", "mcp_tool_call"): note("Used a tool")
            case ("item.completed", "error"): error = (item["message"] as? String).map { oneLine($0, 500) } ?? error
            default: break
            }
        case "turn.completed":
            if let u = o["usage"] as? [String: Any] {
                let turn = TokenUsage(input: int(u["input_tokens"]), cachedInput: int(u["cached_input_tokens"]), output: int(u["output_tokens"]))
                usage = (usage ?? TokenUsage()) + turn
            }
        case "turn.failed":
            let e = (o["error"] as? [String: Any])?["message"] as? String ?? o["message"] as? String ?? "The turn failed."
            error = oneLine(e, 500)
        case "error":
            error = oneLine(o["message"] as? String ?? (o["error"] as? [String: Any])?["message"] as? String ?? "The CLI reported an error.", 500)
        default: break
        }
    }

    private mutating func claude(_ type: String, _ o: [String: Any]) {
        if let s = o["session_id"] as? String, !s.isEmpty { sessionID = s }
        switch type {
        case "assistant":
            let content = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content where block["type"] as? String == "tool_use" {
                switch block["name"] as? String ?? "" {
                case "Read": note("Read file")
                case "Glob", "Grep": note("Searched files")
                case "Edit", "Write": note("Edited file")
                case "WebFetch": note("Fetched a web page")
                case "WebSearch": note("Searched the web")
                default: note("Used a tool")
                }
            }
        case "result":
            if let r = o["result"] as? String { finalText = r }
            if let s = o["structured_output"], JSONSerialization.isValidJSONObject(s),
               let data = try? JSONSerialization.data(withJSONObject: s) { structured = data }
            if let u = o["usage"] as? [String: Any] {
                usage = TokenUsage(input: int(u["input_tokens"]) + int(u["cache_read_input_tokens"]) + int(u["cache_creation_input_tokens"]),
                                   cachedInput: int(u["cache_read_input_tokens"]), output: int(u["output_tokens"]))
            }
            if (o["is_error"] as? Bool) == true || (o["subtype"] as? String).map({ $0 != "success" }) == true {
                let errors = (o["errors"] as? [Any])?.compactMap { $0 as? String }.joined(separator: "; ")
                error = oneLine(errors.flatMap { $0.isEmpty ? nil : $0 } ?? (o["result"] as? String) ?? (o["subtype"] as? String) ?? "The CLI reported an error.", 500)
            }
        default: break
        }
    }

    private mutating func setFinal(_ text: String) {
        finalText = text
        if let d = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) is [String: Any] { structured = d }
    }

    private mutating func note(_ line: String) {
        activity.append(line)
        if activity.count > Self.maxActivity { activity.removeFirst(activity.count - Self.maxActivity) }
    }

    private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    private func oneLine(_ s: String, _ max: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
