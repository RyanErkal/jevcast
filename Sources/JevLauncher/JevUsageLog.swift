import Foundation
import LauncherCore

/// Daily Jev token counts, stored on this Mac in preferences. Nothing leaves the Mac.
@MainActor
final class JevUsageLog: ObservableObject {
    static let shared = JevUsageLog()

    @Published private(set) var ledger: [String: JevDayUsage]
    private let defaults: UserDefaults
    private static let key = "jevUsage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledger = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: JevDayUsage].self, from: $0) } ?? [:]
    }

    /// `cost` is the amount the service reported. Without one, the list price for the input tokens is used.
    func record(inputTokens: Int, outputTokens: Int, cost: Double? = nil, now: Date = Date()) {
        let input = max(inputTokens, 0)
        let dollars = cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? Double(input) * JevPricing.dollarsPerInputToken
        update(now) { $0.requests += 1; $0.inputTokens += input; $0.outputTokens += max(outputTokens, 0); $0.cost += dollars }
    }

    /// Jev's answer moved a result to the top.
    func recordMatch(now: Date = Date()) { update(now) { $0.matches += 1 } }

    /// The launcher answered from memory, so no request was sent.
    func recordSaved(now: Date = Date()) { update(now) { $0.saved += 1 } }

    func summary(days: Int?, now: Date = Date()) -> JevUsageSummary {
        JevUsageLedger.summary(ledger, days: days, now: now)
    }

    func reset() {
        ledger = [:]
        defaults.removeObject(forKey: Self.key)
    }

    private func update(_ now: Date, _ change: (inout JevDayUsage) -> Void) {
        let day = JevUsageLedger.key(for: now)
        var usage = ledger[day] ?? JevDayUsage()
        change(&usage)
        ledger[day] = usage
        defaults.set(try? JSONEncoder().encode(ledger), forKey: Self.key)
    }
}
