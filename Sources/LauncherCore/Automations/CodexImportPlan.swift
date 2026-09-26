import Foundation

/// Values read from a Codex prompt. Suggestions only; the user confirms them before enabling.
public struct CodexSuggestion: Equatable, Sendable {
    public var model: String?
    public var effort: ReasoningEffort?
    /// Only set when the folder exists. There is no default.
    public var workingDirectory: String?
}

extension CodexImport {
    /// Reads "Use <model> with <effort> reasoning" from the first line, and a folder from "In /path," or "from /path".
    public static func suggestion(for prompt: String, folderExists: (String) -> Bool = defaultFolderExists) -> CodexSuggestion {
        let firstLine = prompt.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var result = CodexSuggestion()
        let modelPattern = #"^\s*Use\s+([A-Za-z0-9._:/-]+)\s+with\s+(extra[ -]high|none|low|medium|high|xhigh|max)\s+reasoning"#
        if let m = firstMatch(modelPattern, in: firstLine, options: [.caseInsensitive]) {
            result.model = m[1]
            result.effort = effort(m[2])
        }
        let dirPattern = #"(?:\bWork from|\bfrom|\bIn)\s+(/[^\s,;:"'`)]+)"#
        for m in allMatches(dirPattern, in: prompt, options: []) {
            var path = m[1]
            while path.count > 1, path.hasSuffix(".") || path.hasSuffix("/") { path.removeLast() }
            let standardized = (path as NSString).standardizingPath
            guard !standardized.contains("\0"), folderExists(standardized) else { continue }
            result.workingDirectory = standardized
            break
        }
        return result
    }

    public static func defaultFolderExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func effort(_ word: String) -> ReasoningEffort? {
        let w = word.lowercased().replacingOccurrences(of: "-", with: " ")
        return w == "extra high" ? .xhigh : ReasoningEffort(rawValue: w)
    }

    /// A paused agent automation that keeps the original prompt intact. Check `importIssues` before enabling.
    public static func makeAutomation(from codex: CodexAutomation, timeZone: String, anchor: Date,
                                      folderExists: (String) -> Bool = defaultFolderExists) -> Automation {
        let s = suggestion(for: codex.prompt, folderExists: folderExists)
        let task = AgentTask(runner: .codex, prompt: codex.prompt, model: s.model ?? "", effort: s.effort ?? .medium,
                             workingDirectory: s.workingDirectory ?? "", access: .readOnly, output: .report)
        var rule = codex.rrule
        if rule.uppercased().hasPrefix("RRULE:") { rule = String(rule.dropFirst(6)) }
        let name = codex.name.isEmpty ? codex.id : codex.name
        return Automation(id: AutomationID.make(from: name), name: name, kind: .agent(task),
                          schedule: Schedule(rule: rule.isEmpty ? .manual : .rrule(rule), timeZone: timeZone, anchor: anchor),
                          enabled: false, created: anchor,
                          source: .init(app: .codex, sourceID: codex.id, path: codex.path, hash: codex.hash))
    }

    /// Reasons the import must not be enabled yet. Write words mean "review needed", not proof of writes.
    public static func importIssues(for codex: CodexAutomation, folderExists: (String) -> Bool = defaultFolderExists) -> [String] {
        var issues: [String] = []
        if let error = codex.error { issues.append("Source could not be read: \(error)") }
        let s = suggestion(for: codex.prompt, folderExists: folderExists)
        if s.workingDirectory == nil { issues.append("No working folder found. Choose one.") }
        if s.model == nil { issues.append("No model found. Choose one.") }
        if s.effort == nil { issues.append("No reasoning effort found. Choose one.") }
        if codex.status == .active { issues.append("Still active in Codex. Pause it there first.") }
        let writes = #"\b(write|writes|writing|edit|edits|commit|commits|committing|push|pushes|pushing|draft|drafts|drafting|send|sends|sending|post|posts|posting|deploy|deploys|delete|deletes)\b"#
        if firstMatch(writes, in: codex.prompt, options: [.caseInsensitive]) != nil {
            issues.append("Review needed: the prompt mentions writing, committing, pushing, drafting, or sending.")
        }
        let agents = #"\b(sub-?agents?|spawn_agent|spawn agents?|workers?)\b"#
        if firstMatch(agents, in: codex.prompt, options: [.caseInsensitive]) != nil {
            issues.append("Review needed: the prompt uses subagents.")
        }
        return issues
    }

    private static func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options) -> [String]? {
        allMatches(pattern, in: text, options: options).first
    }

    private static func allMatches(_ pattern: String, in text: String, options: NSRegularExpression.Options) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}
