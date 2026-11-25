import Foundation

/// One-click return times for Snooze: later today, tomorrow morning, and next week.
public struct MailSnoozePreset: Equatable, Sendable, Identifiable {
    public let title: String
    public let date: Date
    public var id: String { title }

    /// The hour a morning return uses.
    public static let morningHour = 8
    /// "Later today" is at least this many hours away, on the next full hour.
    public static let laterHours = 3

    /// The presets for `now`. "Later today" is left out when it would fall on another day.
    public static func presets(now: Date, calendar: Calendar = .current) -> [MailSnoozePreset] {
        var result: [MailSnoozePreset] = []
        if let later = laterToday(now: now, calendar: calendar) { result.append(.init(title: "Later today", date: later)) }
        if let tomorrow = morning(daysAfter: 1, now: now, calendar: calendar) { result.append(.init(title: "Tomorrow morning", date: tomorrow)) }
        if let week = nextWeek(now: now, calendar: calendar) { result.append(.init(title: "Next week", date: week)) }
        return result
    }

    static func laterToday(now: Date, calendar: Calendar) -> Date? {
        let soon = now.addingTimeInterval(Double(laterHours) * 3600)
        guard let hour = calendar.dateInterval(of: .hour, for: soon) else { return nil }
        let rounded = hour.start == soon ? soon : hour.end
        return calendar.isDate(rounded, inSameDayAs: now) ? rounded : nil
    }

    static func morning(daysAfter days: Int, now: Date, calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return nil }
        return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day)
    }

    /// Next Monday morning. On a Monday it is the Monday a week later.
    static func nextWeek(now: Date, calendar: Calendar) -> Date? {
        let weekday = calendar.component(.weekday, from: now)
        let days = (9 - weekday) % 7
        return morning(daysAfter: days == 0 ? 7 : days, now: now, calendar: calendar)
    }
}
