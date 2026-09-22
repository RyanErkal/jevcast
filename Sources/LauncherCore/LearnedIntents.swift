import Foundation

/// Requests the user has already resolved, stored on this Mac. When the same
/// request comes again, the launcher answers from here and does not call Jev.
public struct LearnedIntents: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var count: Int
        public var lastUsed: Date
    }
    public private(set) var entries: [String: Entry] = [:]
    public static let limit = 500

    public init() {}

    /// Lowercase, single-spaced, without surrounding punctuation or filler, so
    /// "Make it bigger, please." and "make it bigger" are one request.
    public static func normalize(_ query: String) -> String {
        let filler: Set<String> = ["please", "pls", "plz", "thanks", "hey", "jev"]
        let words = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !filler.contains($0) }
        return words.joined(separator: " ")
    }

    /// Records that `query` meant `id`. A different answer for the same request replaces the old one.
    public mutating func record(_ query: String, id: String, now: Date = Date()) {
        let key = Self.normalize(query)
        guard key.count >= 2 else { return }
        if var entry = entries[key], entry.id == id {
            entry.count += 1; entry.lastUsed = now; entries[key] = entry
        } else {
            entries[key] = Entry(id: id, count: 1, lastUsed: now)
        }
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(entries.count - Self.limit)
            for (key, _) in oldest { entries.removeValue(forKey: key) }
        }
    }

    public func lookup(_ query: String) -> String? {
        entries[Self.normalize(query)]?.id
    }

    public mutating func forget(_ query: String) {
        entries.removeValue(forKey: Self.normalize(query))
    }

    /// Drops every entry that points at `id`, for an item the user removed.
    public mutating func forget(id: String) {
        entries = entries.filter { $0.value.id != id }
    }
}
