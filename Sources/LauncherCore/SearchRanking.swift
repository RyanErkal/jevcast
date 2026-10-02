import Foundation

/// A small, deterministic ranker for the action names shown by Jev.
///
/// The rank is intended for ordering candidates, rather than as a probability.
/// Exact matches are always higher than prefixes, token matches, and fuzzy
/// matches. A `nil` result means that there is no useful relationship between
/// the query and the supplied action name.
public enum SearchRanking {
    public struct Query: Sendable {
        let forms: [String]
        public var intent: String { forms.first ?? "" }
        public var literal: String { forms.last ?? "" }
        public init(_ text: String) { forms = SearchRanking.forms(for: text) }
        public init(literal text: String) {
            let normalized = normalize(text)
            forms = normalized.isEmpty ? [] : [normalized]
        }
    }

    public enum CandidateStyle: Sendable { case action, name }

    /// Names keep every meaningful word. Action labels can omit a leading verb.
    public struct Candidate: Sendable {
        let forms: [String]
        public init(title: String, aliases: [String] = [], style: CandidateStyle = .action) {
            forms = ([title] + aliases).flatMap { name in
                let split = splitCamelCase(name)
                let names = split == name ? [name] : [name, split]
                return names.flatMap { style == .name ? [normalize($0)] : SearchRanking.forms(for: $0) }
            }.filter { !$0.isEmpty }
        }
    }

    public static func score(
        query: String,
        title: String,
        aliases: [String] = []
    ) -> Double? {
        score(query: Query(query), candidate: Candidate(title: title, aliases: aliases))
    }

    public static func score(query: Query, candidate: Candidate) -> Double? {
        guard !query.forms.isEmpty else { return nil }
        var best: Double?
        for queryForm in query.forms {
            for candidateForm in candidate.forms {
                if let value = score(form: queryForm, against: candidateForm), value > (best ?? 0) {
                    best = value
                }
            }
        }
        return best
    }

    /// Personal use may reorder a tier, but never cross into a stronger tier.
    public static func boosted(_ score: Double, by boost: Double) -> Double {
        let ceiling: Double
        switch score {
        case 100...: return score + max(0, boost)
        case 90..<100: ceiling = 100
        case 56..<90: ceiling = 90
        case 50..<56: ceiling = 56
        case 40..<50: ceiling = 50
        default: ceiling = 40
        }
        return min(score + max(0, boost), ceiling - 0.001)
    }

    private struct SearchForms {
        let full: String
        let core: String

        var all: [String] {
            if core.isEmpty || core == full {
                return [full]
            }
            return [core, full]
        }
    }

    private static let commandWords: Set<String> = [
        "activate", "arrange", "change", "execute", "find", "focus",
        "go", "invoke", "launch", "move", "open", "place", "put",
        "resize", "run", "search", "send", "set", "show", "snap",
        "start", "switch", "tile", "to", "use"
    ]

    // These words are useful in a spoken request but do not identify an
    // action. They are removed only from the command-oriented core form.
    private static let fillerWords: Set<String> = [
        "a", "an", "app", "application", "command", "please", "the",
        "this", "to", "window"
    ]

    private static func forms(for text: String) -> [String] {
        let full = normalize(text)
        guard !full.isEmpty else { return [] }

        let words = full.split(separator: " ").map(String.init)
        var firstMeaningfulWord = 0
        while firstMeaningfulWord < words.count,
              commandWords.contains(words[firstMeaningfulWord]) {
            firstMeaningfulWord += 1
        }

        let remainder = words.dropFirst(firstMeaningfulWord)
        let coreWords = remainder.filter { !fillerWords.contains($0) }
        let core = coreWords.joined(separator: " ")
        guard !core.isEmpty else { return [full] }

        let result = SearchForms(full: full, core: core)
        return result.all
    }

    /// "FaceTime" -> "Face Time", "VSCode" -> "VS Code", "iMovie" -> "i Movie".
    private static func splitCamelCase(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            if index > 0, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || (previous.isUppercase && nextIsLower) {
                    result.append(" ")
                }
            }
            result.append(character)
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        var result = ""
        var pendingSpace = false
        let allowed = CharacterSet.alphanumerics

        for scalar in folded.unicodeScalars {
            if allowed.contains(scalar) {
                if pendingSpace && !result.isEmpty {
                    result.append(" ")
                }
                result.unicodeScalars.append(scalar)
                pendingSpace = false
            } else if !result.isEmpty {
                pendingSpace = true
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Tiers: exact 1.0, whole prefix 0.90, words 0.56-0.84 (exact words
    // above word prefixes), acronym 0.50-0.55, substring 0.40-0.48,
    // fuzzy 0.28-0.38.
    private static func score(form query: String, against candidate: String) -> Double? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }

        if query == candidate {
            return 1.0
        }

        if candidate.hasPrefix(query) {
            return 0.90
        }

        // Spaces and brackets ignored: "t3code" finds "T3 Code (Nightly)", "facetime" finds "Face Time".
        let joinedQuery = query.replacingOccurrences(of: " ", with: "")
        let joinedCandidate = candidate.replacingOccurrences(of: " ", with: "")
        if joinedQuery.count >= 3, joinedCandidate.hasPrefix(joinedQuery) {
            return joinedQuery == joinedCandidate ? 1 : 0.90
        }

        let queryTokens = query.split(separator: " ").map(String.init)
        let candidateTokens = candidate.split(separator: " ").map(String.init)
        let querySet = Set(queryTokens)
        let candidateSet = Set(candidateTokens)

        // A word prefix counts slightly less than a whole word. One-letter
        // prefixes count only when they are the whole query.
        let matchWeight = querySet.reduce(0.0) { total, token in
            if candidateSet.contains(token) { return total + 1 }
            guard token.count >= 2 || querySet.count == 1 else { return total }
            let best = candidateTokens.filter { $0.hasPrefix(token) }.map { Double(token.count) / Double($0.count) }.max()
            return total + (best.map { 0.85 + 0.10 * $0 } ?? 0)
        }

        let matchedTokens = querySet.filter { token in
            candidateSet.contains(token) || ((token.count >= 2 || querySet.count == 1) && candidateTokens.contains { $0.hasPrefix(token) })
        }.count
        if matchedTokens == querySet.count {
            let coverage = matchWeight / Double(querySet.count)
            let precision = min(1, matchWeight / Double(candidateSet.count))
            // This range is deliberately below the prefix score, even when
            // every query token occurs in a long candidate title.
            return min(0.84, 0.56 + (0.20 * coverage) + (0.08 * precision))
        }

        guard query.count >= 2 else { return nil }
        let compactQuery = queryTokens.joined()
        let compactCandidate = candidateTokens.joined()
        guard compactQuery.count >= 2 else { return nil }

        let acronym = candidateTokens.compactMap { $0.first }.map(String.init).joined()
        if acronym == compactQuery {
            return 0.55
        }
        if acronym.hasPrefix(compactQuery) {
            return 0.50 + 0.04 * Double(compactQuery.count) / Double(acronym.count)
        }

        let density = Double(compactQuery.count) / Double(compactCandidate.count)
        if compactCandidate.contains(compactQuery) {
            return 0.40 + 0.08 * density
        }

        if isSubsequence(compactQuery, of: compactCandidate) { return 0.28 + 0.10 * density }
        // A shared word with unrelated words is a weak suggestion, never a word match.
        return matchedTokens > 0 ? 0.28 + 0.10 * Double(matchedTokens) / Double(querySet.count) : nil
    }

    private static func isSubsequence(_ query: String, of candidate: String) -> Bool {
        var candidateIndex = candidate.startIndex
        for character in query {
            guard let match = candidate[candidateIndex...].firstIndex(of: character) else {
                return false
            }
            candidateIndex = candidate.index(after: match)
        }
        return true
    }
}
