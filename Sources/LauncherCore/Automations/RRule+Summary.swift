import Foundation

extension RRule {
    /// A short phrase for rows: "Every 4 hours", "Weekdays at 04:30", "Mon, Thu, Sat at 04:00",
    /// "Hourly · On the hour". With no BYHOUR or BYMINUTE the anchor's local time fills in.
    /// A long list of times is shortened; `timeList(anchor:timeZone:)` gives every time.
    public func summary(anchor: Date? = nil, timeZone: TimeZone = .current) -> String {
        if frequency == .hourly { return interval == 1 ? "Every hour" : "Every \(interval) hours" }
        let times = times(anchor: anchor, timeZone: timeZone)
        let everyDay = weekdays.isEmpty || Set(weekdays) == Set(1...7)
        if let hourly = hourlyPhrase(times) {
            if everyDay, interval == 1 { return "Hourly · " + hourly.capitalizedFirst }
            return dayPrefix(anchor: anchor, timeZone: timeZone) + ", hourly " + hourly
        }
        let at = (times.count > Self.maxListedTimes ? ", " : " at ") + timePhrase(times)
        return dayPrefix(anchor: anchor, timeZone: timeZone) + at
    }

    /// Every time of day the rule runs, in order: "00:00, 01:00 and 02:00".
    public func timeList(anchor: Date? = nil, timeZone: TimeZone = .current) -> String {
        Self.joined(times(anchor: anchor, timeZone: timeZone).map(Self.clock))
    }

    /// True when `summary` leaves some times out.
    public func summaryShortensTimes(anchor: Date? = nil, timeZone: TimeZone = .current) -> Bool {
        guard frequency != .hourly else { return false }
        let times = times(anchor: anchor, timeZone: timeZone)
        return hourlyPhrase(times) == nil && times.count > Self.maxListedTimes
    }

    static let maxListedTimes = 4

    /// "Daily", "Every 2 days", "Weekdays", "Mon, Thu", "Every 2 weeks on Sat".
    private func dayPrefix(anchor: Date?, timeZone: TimeZone) -> String {
        if frequency == .daily || Set(weekdays) == Set(1...7) {
            let prefix = frequency == .daily ? (interval == 1 ? "Daily" : "Every \(interval) days") : (interval == 1 ? "Daily" : "Every \(interval) weeks, daily")
            if frequency == .daily, !weekdays.isEmpty, Set(weekdays) != Set(1...7) { return prefix + " on " + dayNames(weekdays) }
            return prefix
        }
        var days = weekdays
        if days.isEmpty, let anchor {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
            days = [cal.component(.weekday, from: anchor)]
        }
        let every = interval == 1 ? "" : "Every \(interval) weeks on "
        let name: String
        switch Set(days) {
        case Set(2...6): name = interval == 1 ? "Weekdays" : "weekdays"
        case [1, 7]: name = interval == 1 ? "Weekends" : "weekends"
        default: name = days.isEmpty ? "Weekly" : dayNames(days)
        }
        return every + name
    }

    /// "on the hour" or "at :15 and :45" when the rule runs in every hour of the day at the same minutes.
    private func hourlyPhrase(_ times: [(hour: Int, minute: Int)]) -> String? {
        let hoursSeen = Set(times.map(\.hour))
        guard hoursSeen == Set(0...23) else { return nil }
        let minutes = Array(Set(times.map(\.minute))).sorted()
        guard times.count == 24 * minutes.count else { return nil }
        if minutes == [0] { return "on the hour" }
        return "at " + Self.joined(minutes.map { String(format: ":%02d", $0) })
    }

    /// Up to four times in full; more as a count with the first and last: "6 times from 01:00 to 22:00".
    private func timePhrase(_ times: [(hour: Int, minute: Int)]) -> String {
        guard times.count > Self.maxListedTimes, let first = times.first, let last = times.last else {
            return Self.joined(times.map(Self.clock))
        }
        return "\(times.count) times from \(Self.clock(first)) to \(Self.clock(last))"
    }

    private func dayNames(_ days: [Int]) -> String {
        let names = [2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat", 1: "Sun"]
        return [2, 3, 4, 5, 6, 7, 1].filter(days.contains).compactMap { names[$0] }.joined(separator: ", ")
    }

    private func times(anchor: Date?, timeZone: TimeZone) -> [(hour: Int, minute: Int)] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let parts = anchor.map { cal.dateComponents([.hour, .minute], from: $0) }
        let hs = hours.isEmpty ? [parts?.hour ?? 0] : hours
        let ms = minutes.isEmpty ? [parts?.minute ?? 0] : minutes
        return hs.flatMap { h in ms.map { (hour: h, minute: $0) } }
    }

    private static func clock(_ t: (hour: Int, minute: Int)) -> String { String(format: "%02d:%02d", t.hour, t.minute) }

    private static func joined(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
