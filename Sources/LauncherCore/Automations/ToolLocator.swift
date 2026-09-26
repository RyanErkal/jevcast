import Foundation

/// Where to look for the `codex` and `claude` CLIs. Never asks a login shell: its startup files run code.
public enum ToolLocator {
    /// Candidate paths, in order: the saved path, then fixed folders, then the newest nvm Node, then Bun.
    public static func candidates(name: String, saved: String, home: String, nvmVersions: [String]) -> [String] {
        var list: [String] = []
        if !saved.isEmpty { list.append(saved) }
        list += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].map { $0 + "/" + name }
        if let newest = nvmVersions.sorted(by: newerVersion).first { list.append("\(home)/.nvm/versions/node/\(newest)/bin/\(name)") }
        list.append("\(home)/.bun/bin/\(name)")
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// "v22.3.0" before "v20.11.1". Non-numeric parts count as 0.
    static func newerVersion(_ a: String, _ b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return a > b
    }

    /// The first line of `--version` output, trimmed and bounded.
    public static func versionLine(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : String(line.prefix(80))
    }
}

extension ApplyJournal {
    /// "Moved 12, trashed 3, skipped 1". Failed items are counted too.
    public var summaryText: String {
        var counts: [(String, Int)] = []
        func count(_ ops: Set<ProposalItem.Operation>) -> Int { entries.filter { $0.status == .done && ops.contains($0.op) }.count }
        counts.append(("Moved", count([.move])))
        counts.append(("renamed", count([.rename])))
        counts.append(("created", count([.mkdir])))
        counts.append(("trashed", count([.trash])))
        counts.append(("tagged", count([.tag])))
        counts.append(("skipped", entries.filter { $0.status == .skipped }.count))
        counts.append(("failed", entries.filter { $0.status == .failed }.count))
        let parts = counts.filter { $0.1 > 0 }.map { "\($0.0.lowercased()) \($0.1)" }
        guard let first = parts.first else { return "Nothing changed" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }

    /// True when at least one item failed or was skipped.
    public var hasProblems: Bool { entries.contains { $0.status == .failed || $0.status == .skipped } }
    public var failed: Bool { entries.contains { $0.status == .failed } }
}

extension ApplyJournal {
    public static let fileName = "journal.json"

    /// Reads `journal.json` as `ProposalApplier` writes it (ISO 8601 dates).
    public static func decode(_ data: Data) -> ApplyJournal? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ApplyJournal.self, from: data)
    }
}
