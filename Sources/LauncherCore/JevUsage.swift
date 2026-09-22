import Foundation

/// One day of Jev use. Stored per local calendar day.
public struct JevDayUsage: Codable, Equatable, Sendable {
    public var requests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    /// Requests whose answer moved a result to the top.
    public var matches = 0
    /// Requests the launcher answered from memory instead of calling Jev.
    public var saved = 0
    /// US dollars the service reported, plus the list price for requests without a reported cost.
    public var cost = 0.0
    public init() {}

    private enum CodingKeys: String, CodingKey { case requests, inputTokens, outputTokens, matches, saved, cost }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        matches = try c.decodeIfPresent(Int.self, forKey: .matches) ?? 0
        saved = try c.decodeIfPresent(Int.self, forKey: .saved) ?? 0
        // Days stored before costs were kept are priced from their tokens.
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? Double(inputTokens) * JevPricing.dollarsPerInputToken
    }
}

/// Totals for a window of days, with the cost at the published Jev price.
public struct JevUsageSummary: Equatable, Sendable {
    public var requests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var matches = 0
    public var saved = 0
    /// US dollars, as reported by the service or at the list price.
    public var cost = 0.0
    public var averageInputTokens: Int { requests == 0 ? 0 : inputTokens / requests }
}

public enum JevPricing {
    /// jev-1.13.0: $0.042 per million input tokens. Output tokens are free (docs.typesafe.ai/models).
    public static let dollarsPerMillionInputTokens = 0.042
    public static let dollarsPerInputToken = dollarsPerMillionInputTokens / 1_000_000

    /// "$0.000081" for tiny amounts, "$1.23" otherwise.
    public static func format(_ dollars: Double) -> String {
        if dollars == 0 { return "$0.00" }
        if dollars < 0.01 { return String(format: "$%.6f", dollars) }
        return String(format: "$%.2f", dollars)
    }
}

public enum JevUsageLedger {
    /// "2026-09-23" in the given calendar's time zone.
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Totals for the last `days` calendar days including today, or all days when `days` is nil.
    public static func summary(_ ledger: [String: JevDayUsage], days: Int?, now: Date = Date(), calendar: Calendar = .current) -> JevUsageSummary {
        var keys: Set<String>?
        if let days {
            let today = calendar.startOfDay(for: now)
            keys = Set((0..<max(days, 1)).compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: today).map { key(for: $0, calendar: calendar) }
            })
        }
        var total = JevUsageSummary()
        for (day, usage) in ledger where keys?.contains(day) ?? true {
            total.requests += usage.requests
            total.inputTokens += usage.inputTokens
            total.outputTokens += usage.outputTokens
            total.matches += usage.matches
            total.saved += usage.saved
            total.cost += usage.cost
        }
        return total
    }
}
