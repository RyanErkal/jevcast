import Foundation

extension RRule {
    /// Days scanned before giving up, so a rule that never matches cannot loop for long.
    static let maxScanDays = 8000

    /// Occurrences strictly after `after`, never before `anchor`, ascending, at most `limit`.
    /// HOURLY steps by elapsed time from the anchor. DAILY and WEEKLY use wall time in `timeZone`:
    /// a time that does not exist (spring forward) is skipped, a repeated time (fall back) fires once.
    public func occurrences(after: Date, anchor: Date, timeZone: TimeZone, limit: Int) -> [Date] {
        guard limit > 0 else { return [] }
        let cap = min(limit, 10_000)
        if frequency == .hourly { return hourly(after: after, anchor: anchor, limit: cap) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let anchorParts = cal.dateComponents([.hour, .minute, .weekday], from: anchor)
        let hourList = hours.isEmpty ? [anchorParts.hour ?? 0] : hours
        let minuteList = minutes.isEmpty ? [anchorParts.minute ?? 0] : minutes
        let times = hourList.flatMap { h in minuteList.map { (h, $0) } }
        let dayList: Set<Int> = weekdays.isEmpty ? (frequency == .weekly ? [anchorParts.weekday ?? 1] : Set(1...7)) : Set(weekdays)
        // Weeks start on Monday (RFC 5545 default WKST).
        let anchorMondayOffset = ((anchorParts.weekday ?? 2) + 5) % 7
        let anchorDay = cal.startOfDay(for: anchor)
        let startDay = cal.startOfDay(for: max(after, anchor))
        var dayIndex = cal.dateComponents([.day], from: anchorDay, to: startDay).day ?? 0
        var day = noon(of: startDay, cal)
        var result: [Date] = []
        for _ in 0..<Self.maxScanDays {
            let parts = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            if dayList.contains(parts.weekday ?? 0), matchesInterval(dayIndex: dayIndex, mondayOffset: anchorMondayOffset) {
                for (h, m) in times {
                    guard let date = wallTime(parts, hour: h, minute: m, cal), date > after, date >= anchor else { continue }
                    result.append(date)
                    if result.count >= cap { return result }
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = noon(of: next, cal); dayIndex += 1
        }
        return result
    }

    private func hourly(after: Date, anchor: Date, limit: Int) -> [Date] {
        let step = Double(interval) * 3600
        var k = after < anchor ? 0 : Int(((after.timeIntervalSince(anchor)) / step).rounded(.down)) + 1
        var result: [Date] = []
        while result.count < limit {
            let date = anchor.addingTimeInterval(Double(k) * step)
            if date > after { result.append(date) }
            k += 1
        }
        return result
    }

    private func matchesInterval(dayIndex: Int, mondayOffset: Int) -> Bool {
        guard interval > 1 else { return true }
        switch frequency {
        case .daily: return dayIndex % interval == 0
        case .weekly:
            let week = Int((Double(dayIndex + mondayOffset) / 7).rounded(.down))
            return week % interval == 0
        case .hourly: return true
        }
    }

    private func noon(of day: Date, _ cal: Calendar) -> Date {
        cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    /// The date for this wall time, or nil when the clock skips it. For a repeated hour Foundation picks the first.
    private func wallTime(_ day: DateComponents, hour: Int, minute: Int, _ cal: Calendar) -> Date? {
        var c = DateComponents(); c.year = day.year; c.month = day.month; c.day = day.day; c.hour = hour; c.minute = minute; c.second = 0
        guard let date = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.day, .hour, .minute], from: date)
        return back.day == day.day && back.hour == hour && back.minute == minute ? date : nil
    }
}
