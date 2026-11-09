import Foundation

/// What the event editor holds: a new event, or the changed fields of an existing one.
public struct CalendarEventDraft: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendarID: String?
    public var location: String
    public var notes: String

    public init(title: String = "", start: Date, end: Date, allDay: Bool = false, calendarID: String? = nil,
                location: String = "", notes: String = "") {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay
        self.calendarID = calendarID; self.location = location; self.notes = notes
    }

    /// A new one-hour event at the next half hour of `day`, or at `minute` of that day when given.
    public static func new(on day: Date, minute: Int? = nil, now: Date = Date(), calendar: Calendar = .current) -> CalendarEventDraft {
        let midnight = calendar.startOfDay(for: day)
        let startMinute: Int
        if let minute { startMinute = max(0, min(23 * 60 + 30, minute / 15 * 15)) }
        else if calendar.isDate(day, inSameDayAs: now) {
            let passed = Int(now.timeIntervalSince(midnight) / 60)
            startMinute = min(23 * 60, (passed / 30 + 1) * 30)
        } else { startMinute = 9 * 60 }
        let start = calendar.date(byAdding: .minute, value: startMinute, to: midnight) ?? midnight
        return CalendarEventDraft(start: start, end: start.addingTimeInterval(3600))
    }

    public var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the draft cannot be saved, or nil when it can.
    public var problem: String? {
        if trimmedTitle.isEmpty { return "Add a title." }
        if trimmedTitle.count > 500 { return "The title is too long." }
        if !allDay && end <= start { return "The end must be after the start." }
        if allDay && end < start { return "The last day must not be before the first day." }
        if end.timeIntervalSince(start) > 366 * 86_400 { return "An event can be at most one year long." }
        return nil
    }

    /// The times to store. An all-day event covers whole days: from the start of its first day to
    /// the start of the day after its last day.
    public func storedTimes(calendar: Calendar = .current) -> (start: Date, end: Date) {
        guard allDay else { return (start, end) }
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: max(start, end))
        return (first, calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400))
    }

    /// The draft moved by whole minutes and whole days, keeping its length. A drag in the grid uses it.
    public func moved(minutes: Int, days: Int, calendar: Calendar = .current) -> CalendarEventDraft {
        var copy = self
        let length = end.timeIntervalSince(start)
        var next = calendar.date(byAdding: .day, value: days, to: start) ?? start
        if !allDay { next = next.addingTimeInterval(Double(minutes) * 60) }
        copy.start = next; copy.end = next.addingTimeInterval(length)
        return copy
    }

    /// Snaps a dragged distance to quarter hours.
    public static func snappedMinutes(_ minutes: Double) -> Int { Int((minutes / 15).rounded()) * 15 }
}

/// Matches the calendar filter against everything the event shows, not only its title.
public enum CalendarEventFilter {
    public static func matches(_ words: String, fields: [String]) -> Bool {
        let terms = words.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let text = fields.joined(separator: "\n").lowercased()
        return terms.allSatisfy { text.contains($0) }
    }
}
