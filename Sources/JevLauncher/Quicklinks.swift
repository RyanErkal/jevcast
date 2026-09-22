import Foundation

/// A search keyword: `keyword` followed by text opens `template` with `{query}` replaced.
struct Quicklink: Codable, Identifiable, Equatable, Hashable {
    var keyword: String
    var name: String
    var template: String
    var id: String { keyword.lowercased() }

    static let placeholder = "{query}"
    static let defaults = [
        Quicklink(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={query}"),
        Quicklink(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query={query}"),
        Quicklink(keyword: "maps", name: "Maps", template: "https://maps.apple.com/?q={query}"),
        Quicklink(keyword: "wiki", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search={query}")
    ]
    private static let queryAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// The URL for `query`. An empty query opens the template's site root.
    func url(for query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if text.isEmpty {
            guard let base = URL(string: template.replacingOccurrences(of: Self.placeholder, with: "")),
                  let scheme = base.scheme, let host = base.host else { return nil }
            value = scheme + "://" + host + "/"
        } else {
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) else { return nil }
            value = template.replacingOccurrences(of: Self.placeholder, with: encoded)
        }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    /// The error that prevents saving, or nil when valid and not a duplicate keyword.
    static func validationError(keyword: String, template: String, existing: [Quicklink]) -> String? {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.isEmpty || word.contains(where: \.isWhitespace) { return "Use one word as the keyword." }
        if existing.contains(where: { $0.id == word.lowercased() }) { return "That keyword is already in use." }
        guard template.contains(placeholder) else { return "Put {query} in the URL where the search text goes." }
        guard Quicklink(keyword: word, name: word, template: template).url(for: "test") != nil else { return "Use an http or https URL." }
        return nil
    }

    /// Splits `text` into a quicklink and its search text when the first word is a keyword.
    static func match(_ text: String, in links: [Quicklink]) -> (link: Quicklink, query: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first, let link = links.first(where: { $0.id == first.lowercased() }) else { return nil }
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (link, rest)
    }
}
