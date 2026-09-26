import Foundation

extension RRule {
    /// A short phrase for rows: "Every 4 hours", "Weekdays at 04:30", "Mon, Thu, Sat at 04:00".
    /// With no BYHOUR or BYMINUTE the anchor's local time fills in.
    public func summary(anchor: Date? = nil, timeZone: TimeZone = .current) -> String {
        if frequency == .hourly { return interval == 1 ? "Every hour" : "Every \(interval) hours" }
        let at = " at " + timeList(anchor: anchor, timeZone: timeZone)
        if frequency == .daily || Set(weekdays) == Set(1...7) {
            let prefix = frequency == .daily ? (interval == 1 ? "Daily" : "Every \(interval) days") : (interval == 1 ? "Daily" : "Every \(interval) weeks, daily")
            if frequency == .daily, !weekdays.isEmpty, Set(weekdays) != Set(1...7) { return prefix + " on " + dayNames(weekdays) + at }
            return prefix + at
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
        return every + name + at
    }

    private func dayNames(_ days: [Int]) -> String {
        let names = [2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat", 1: "Sun"]
        return [2, 3, 4, 5, 6, 7, 1].filter(days.contains).compactMap { names[$0] }.joined(separator: ", ")
    }

    private func timeList(anchor: Date?, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let parts = anchor.map { cal.dateComponents([.hour, .minute], from: $0) }
        let hs = hours.isEmpty ? [parts?.hour ?? 0] : hours
        let ms = minutes.isEmpty ? [parts?.minute ?? 0] : minutes
        let times = hs.flatMap { h in ms.map { String(format: "%02d:%02d", h, $0) } }
        guard times.count > 1 else { return times.first ?? "" }
        return times.dropLast().joined(separator: ", ") + " and " + (times.last ?? "")
    }
}
