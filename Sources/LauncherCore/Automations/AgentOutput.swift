import Foundation

/// A checked agent reply. The schema is enforced by the CLI, but code checks it again here.
public enum AgentOutput: Equatable, Sendable {
    case report(summary: String, markdown: String)
    case question(summary: String, markdown: String, question: String, choices: [String])
    case proposal(Proposal)

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notJSON, missing(String), invalid(String), tooLarge
        public var description: String {
            switch self {
            case .notJSON: return "The agent did not return JSON."
            case .missing(let k): return "The agent's reply has no \(k)."
            case .invalid(let why): return "The agent's reply is not valid: \(why)"
            case .tooLarge: return "The agent's reply is too large."
            }
        }
    }

    static let maxSummary = 500
    static let maxMarkdown = 1_000_000

    /// Parses the JSON object for `mode`. Unused fields may be empty strings or empty arrays.
    public static func parse(_ data: Data, mode: OutputMode) throws -> AgentOutput {
        guard data.count <= max(Proposal.maxBytes, maxMarkdown * 2) else { throw ParseError.tooLarge }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ParseError.notJSON }
        let summary = String(try string(object, "summary").prefix(maxSummary)).replacingOccurrences(of: "\n", with: " ")
        switch mode {
        case .report:
            return .report(summary: summary, markdown: String(try string(object, "report_markdown").prefix(maxMarkdown)))
        case .ask:
            let kind = try string(object, "kind")
            let markdown = String(((object["report_markdown"] as? String) ?? "").prefix(maxMarkdown))
            switch kind {
            case "report": return .report(summary: summary, markdown: markdown)
            case "question":
                let q = try string(object, "question").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else { throw ParseError.missing("question") }
                let choices = ((object["choices"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(5).map { String($0.prefix(200)) }
                return .question(summary: summary, markdown: markdown, question: String(q.prefix(2000)), choices: Array(choices))
            default: throw ParseError.invalid("kind \(kind)")
            }
        case .proposal:
            guard data.count <= Proposal.maxBytes else { throw ParseError.tooLarge }
            guard let rawItems = object["items"] as? [Any] else { throw ParseError.missing("items") }
            guard rawItems.count <= Proposal.maxItems else { throw ParseError.invalid("more than \(Proposal.maxItems) items") }
            var seen = Set<String>()
            let items: [ProposalItem] = try rawItems.map { raw in
                guard let d = raw as? [String: Any] else { throw ParseError.invalid("an item is not an object") }
                let id = try string(d, "id")
                guard !id.isEmpty, seen.insert(id).inserted else { throw ParseError.invalid("item IDs must be unique and not empty") }
                guard let op = ProposalItem.Operation(rawValue: try string(d, "op")) else { throw ParseError.invalid("unknown op in \(id)") }
                func opt(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                let tags = (d["tags"] as? [Any])?.compactMap { $0 as? String }
                return ProposalItem(id: id, op: op, path: opt("path"), from: opt("from"), to: opt("to"), name: opt("name"),
                                    tags: (tags?.isEmpty ?? true) ? nil : tags, reason: (d["reason"] as? String) ?? "")
            }
            return .proposal(Proposal(summary: summary, items: items))
        }
    }

    private static func string(_ o: [String: Any], _ key: String) throws -> String {
        guard let v = o[key] as? String else { throw ParseError.missing(key) }
        return v
    }
}
