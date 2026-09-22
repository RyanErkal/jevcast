import Foundation

/// Small text helpers for turning a spoken or typed request into an argument.
public enum QueryText {
    private static let leadingFiller: Set<String> = [
        "search", "find", "look", "up", "lookup", "show", "me", "for", "on", "in", "at", "the", "a", "an",
        "please", "pls", "can", "you", "could", "go", "to", "open", "google", "query", "about", "videos", "video"
    ]
    private static let trailingFiller: Set<String> = ["please", "pls", "thanks", "on", "for", "in"]

    /// The search text left after removing a site's name or keyword and the filler around it:
    /// "search github for swift ui" → "swift ui", "youtube lofi beats please" → "lofi beats".
    public static func remainder(of query: String, removing names: [String]) -> String {
        var words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let nameWords = names.map { $0.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
        // Remove the first occurrence of the longest matching name.
        for name in nameWords.sorted(by: { $0.count > $1.count }) {
            let lower = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            guard lower.count >= name.count else { continue }
            if let start = (0...(lower.count - name.count)).first(where: { Array(lower[$0..<$0 + name.count]) == name }) {
                words.removeSubrange(start..<start + name.count)
                break
            }
        }
        while let first = words.first, leadingFiller.contains(first.lowercased()) { words.removeFirst() }
        while let last = words.last, trailingFiller.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Replaces the word "ans" with the last answer, for "ans * 2".
    public static func substitutingAnswer(_ expression: String, last: String?) -> String? {
        guard let last else { return nil }
        let pattern = "\\bans\\b"
        guard expression.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let number = last.replacingOccurrences(of: ",", with: "").split(separator: " ").first.map(String.init) ?? last
        guard Double(number) != nil else { return nil }
        return expression.replacingOccurrences(of: pattern, with: "(\(number))", options: [.regularExpression, .caseInsensitive])
    }
}
