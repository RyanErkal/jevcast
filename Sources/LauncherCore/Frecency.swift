import Foundation

/// Bounded, decaying usage memory. `records` rank how often and how recently an
/// ID was run; `picks` remember which ID was run for a typed query, so a
/// one-letter query can learn its usual target. Pure and value-typed for tests.
public struct Frecency: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        /// Use count decayed to `lastUsed`.
        public var count: Double
        public var lastUsed: Date
    }
    public struct Pick: Codable, Equatable, Sendable {
        public var id: String
        public var count: Double
        public var lastUsed: Date
    }

    public static let halfLife: TimeInterval = 14 * 24 * 3600
    public static let maxRecords = 300
    public static let maxPicks = 200
    public static let maxQueryLength = 40

    public private(set) var records: [String: Record] = [:]
    public private(set) var picks: [String: Pick] = [:]

    public init() {}

    /// Seeds records from the old unbounded `[id: count]` store.
    public init(legacyUsage: [String: Int], now: Date = Date()) {
        for (id, count) in legacyUsage where count > 0 {
            records[id] = Record(count: Double(min(count, 20)), lastUsed: now)
        }
        trim(now: now)
    }

    public static func decayed(_ count: Double, from date: Date, to now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(date))
        return count * pow(0.5, age / halfLife)
    }

    public static func queryKey(_ query: String) -> String? {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key.count <= maxQueryLength else { return nil }
        return key
    }

    public func score(_ id: String, now: Date = Date()) -> Double {
        guard let record = records[id] else { return 0 }
        return Self.decayed(record.count, from: record.lastUsed, to: now)
    }

    /// The ID learned for this exact query and its decayed pick count.
    public func learned(for query: String, now: Date = Date()) -> (id: String, count: Double)? {
        guard let key = Self.queryKey(query), let pick = picks[key] else { return nil }
        return (pick.id, Self.decayed(pick.count, from: pick.lastUsed, to: now))
    }

    public mutating func record(_ id: String, query: String, now: Date = Date()) {
        records[id] = Record(count: score(id, now: now) + 1, lastUsed: now)
        if let key = Self.queryKey(query) {
            if var pick = picks[key] {
                let current = Self.decayed(pick.count, from: pick.lastUsed, to: now)
                if pick.id == id { pick.count = current + 1 }
                else if current > 1 { pick.count = current - 1 }
                else { pick = Pick(id: id, count: 1, lastUsed: now) }
                pick.lastUsed = now
                picks[key] = pick
            } else {
                picks[key] = Pick(id: id, count: 1, lastUsed: now)
            }
        }
        trim(now: now)
    }

    public mutating func remove(_ id: String) {
        records[id] = nil
        picks = picks.filter { $0.value.id != id }
    }

    /// A 0..<1 boost. Callers scale it below the gap between ranking tiers so it
    /// reorders close matches without lifting a weak match over an exact one.
    public func boost(for id: String, query: String, now: Date = Date()) -> Double {
        let used = score(id, now: now)
        var value = 0.35 * used / (used + 5)
        if let learned = learned(for: query, now: now), learned.id == id {
            value += 0.65 * learned.count / (learned.count + 1)
        }
        return min(value, 0.999)
    }

    private mutating func trim(now: Date) {
        if records.count > Self.maxRecords {
            let keep = Set(records.map { ($0.key, Self.decayed($0.value.count, from: $0.value.lastUsed, to: now)) }
                .sorted { $0.1 > $1.1 }.prefix(Self.maxRecords).map(\.0))
            records = records.filter { keep.contains($0.key) }
        }
        if picks.count > Self.maxPicks {
            let keep = Set(picks.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(Self.maxPicks).map(\.key))
            picks = picks.filter { keep.contains($0.key) }
        }
    }
}
