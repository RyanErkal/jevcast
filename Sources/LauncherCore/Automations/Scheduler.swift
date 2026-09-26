import Foundation

/// Pure due computation. The runner stores `coveredThrough` so an occurrence is never run twice,
/// even after the clock moves back.
public enum Scheduler {
    /// With `.skip`, an occurrence this close to now still runs; older ones are dropped.
    public static let grace: TimeInterval = 120
    static let pageSize = 1000
    static let maxPages = 200

    public struct Due: Equatable, Sendable {
        /// Occurrences to start now. At most one.
        public var runs: [Date]
        /// The newest occurrence now consumed, run or skipped. Nil when nothing changed.
        public var coveredThrough: Date?
        /// Occurrences dropped by `.skip` or merged by `.runOnce`.
        public var missed: Int
    }

    public static func due(_ automation: Automation, lastCovered: Date?, now: Date) -> Due {
        let none = Due(runs: [], coveredThrough: nil, missed: 0)
        guard automation.enabled else { return none }
        let schedule = automation.schedule
        let pending: (newest: Date, count: Int)?
        switch schedule.rule {
        case .manual: return none
        case .once(let date):
            if let lastCovered, coveredBound(lastCovered) >= date { return none }
            pending = date <= now ? (date, 1) : nil
        case .rrule(let text):
            guard let rule = try? RRule(text) else { return none }
            let after = lastCovered.map(coveredBound) ?? schedule.anchor.addingTimeInterval(-1)
            pending = newest(rule, after: after, upTo: now, schedule: schedule)
        }
        guard let pending else { return none }
        let runsNow: Bool
        switch automation.policy.catchUp {
        case .skip: runsNow = now.timeIntervalSince(pending.newest) <= grace
        case .runOnce: runsNow = true
        }
        return Due(runs: runsNow ? [pending.newest] : [], coveredThrough: pending.newest,
                   missed: pending.count - (runsNow ? 1 : 0))
    }

    /// The next time this automation would start, or nil for manual, paused, finished, or invalid.
    public static func nextRun(_ automation: Automation, lastCovered: Date?, now: Date) -> Date? {
        guard automation.enabled else { return nil }
        let schedule = automation.schedule
        switch schedule.rule {
        case .manual: return nil
        case .once(let date):
            if let lastCovered, coveredBound(lastCovered) >= date { return nil }
            return date
        case .rrule(let text):
            guard let rule = try? RRule(text), let zone = TimeZone(identifier: schedule.timeZone) else { return nil }
            let after = max(now, lastCovered.map(coveredBound) ?? .distantPast)
            return rule.occurrences(after: after, anchor: schedule.anchor, timeZone: zone, limit: 1).first
        }
    }

    /// Tolerates a covered date that lost precision on the way through another tool. Occurrences are minutes apart.
    static func coveredBound(_ date: Date) -> Date { date.addingTimeInterval(0.5) }

    /// The newest occurrence in (after, upTo], and how many there were (bounded count).
    static func newest(_ rule: RRule, after: Date, upTo now: Date, schedule: Schedule) -> (newest: Date, count: Int)? {
        guard let zone = TimeZone(identifier: schedule.timeZone), after < now else { return nil }
        // Only the newest runs, so a long backlog is not walked: start at most 35 days (or one rule period) back.
        // `missed` is exact within that window.
        let period: TimeInterval
        switch rule.frequency {
        case .hourly: period = Double(rule.interval) * 3600
        case .daily: period = Double(rule.interval + 1) * 86400
        case .weekly: period = Double(rule.interval * 7 + 1) * 86400
        }
        var cursor = max(after, now.addingTimeInterval(-max(period + 3600, 35 * 86400))), found: Date?, count = 0
        for _ in 0..<maxPages {
            let page = rule.occurrences(after: cursor, anchor: schedule.anchor, timeZone: zone, limit: pageSize)
            let inRange = page.filter { $0 <= now }
            if let last = inRange.last { found = last; count += inRange.count; cursor = last }
            if inRange.count < page.count || page.count < pageSize { break }
        }
        return found.map { ($0, count) }
    }
}
