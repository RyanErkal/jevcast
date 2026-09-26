import Foundation

/// Why a whole proposal was refused. Item problems refuse only that item.
public enum ProposalError: Error, Equatable, Sendable {
    case tooLarge(Int)
    case invalidJSON(String)
    case unsupportedVersion(Int)
    case tooManyItems(Int)
    case duplicateItemID(String)
    case invalidItemID(String)
    case unknownOperation(String)
    case unexpectedField(String)
    case noRoots
}

/// Checks a proposal against the file system and the user's roots. Roots come only from the caller.
public enum ProposalValidator {
    public static func check(rawJSON: Data, roots: [String], now: Date) -> Result<ProposalManifest, ProposalError> {
        check(rawJSON: rawJSON, roots: roots, now: now, protected: ProtectedPaths.standard)
    }

    static func check(rawJSON: Data, roots: [String], now: Date, protected: [String]) -> Result<ProposalManifest, ProposalError> {
        let proposal: Proposal
        switch ProposalDecoder.decode(rawJSON) {
        case .failure(let e): return .failure(e)
        case .success(let p): proposal = p
        }
        let resolvedRoots = roots.compactMap(ResolvedRoot.init)
        guard !resolvedRoots.isEmpty else { return .failure(.noRoots) }
        let checker = ItemChecker(roots: resolvedRoots, protected: protected.compactMap(SafeFS.components))
        var checked: [CheckedItem] = []
        var refused: [String: String] = [:]
        for item in proposal.items {
            switch checker.check(item) {
            case .success(let c): checked.append(c)
            case .failure(let reason): refused[item.id] = reason.text
            }
        }
        for (id, reason) in dependencies(checked) { refused[id] = reason }
        checked.removeAll { refused[$0.id] != nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let canonical = (try? encoder.encode(proposal)) ?? Data()
        return .success(ProposalManifest(proposal: proposal, checked: checked, refused: refused,
                                         roots: resolvedRoots.map(\.real).map(SafeFS.join), digest: Sha256.hex(canonical), created: now))
    }

    /// Items whose paths overlap (same path, or one inside the other) depend on each other. Both are refused.
    /// Paths compare without case and Unicode form, as APFS does by default, so "a.txt" and "A.txt" count as one.
    static func dependencies(_ items: [CheckedItem]) -> [String: String] {
        let paths = items.map { c in ([c.source] + (c.destination.map { [$0] } ?? [])).map(SafeFS.folded).compactMap(SafeFS.components) }
        var result: [String: String] = [:]
        for a in items.indices {
            for b in items.indices where b > a {
                let overlap = paths[a].contains { pa in paths[b].contains { pb in SafeFS.isInside(pa, pb) || SafeFS.isInside(pb, pa) } }
                guard overlap else { continue }
                result[items[a].id] = "Depends on item \(items[b].id). Approve it in a separate proposal."
                result[items[b].id] = "Depends on item \(items[a].id). Approve it in a separate proposal."
            }
        }
        return result
    }
}

extension ProposalValidator {
    /// Proposals older than this cannot be approved. Their journals stay for undo.
    public static let maxAge: TimeInterval = 7 * 86400

    public static func isExpired(_ manifest: ProposalManifest, now: Date) -> Bool {
        now.timeIntervalSince(manifest.created) > maxAge
    }
}

/// Paths no proposal may touch.
enum ProtectedPaths {
    static var standard: [String] {
        let home = NSHomeDirectory()
        // Jevcast's Application Support folder sits inside ~/Library.
        return ["Library", ".ssh", ".codex", ".claude"].map { home + "/" + $0 } + ["/System", "/usr", "/bin", "/private"]
    }
}

/// A user root, as given and with symlinks resolved.
struct ResolvedRoot {
    var given: [String]
    var real: [String]
    init?(_ path: String) {
        guard let given = SafeFS.components(path), let realC = realpath(path, nil) else { return nil }
        defer { free(realC) }
        guard let real = SafeFS.components(String(cString: realC)), !real.isEmpty else { return nil }
        self.given = given; self.real = real
    }
}
