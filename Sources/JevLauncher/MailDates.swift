import Foundation

/// The dates Mail shows: short where space is tight, full in the tooltip. The list, the reader's
/// header, and each reply in a conversation use the same rule.
enum MailDates {
    enum Style: Equatable { case time, dayMonth, numeric }

    /// Today shows the time, this year the day and month, older mail the numeric date.
    static func style(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> Style {
        if calendar.isDate(date, inSameDayAs: now) { return .time }
        return calendar.isDate(date, equalTo: now, toGranularity: .year) ? .dayMonth : .numeric
    }

    /// "10:51", "25 Nov", or "02/10/2025", in the Mac's own format.
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch style(for: date, now: now, calendar: calendar) {
        case .time: return date.formatted(date: .omitted, time: .shortened)
        case .dayMonth: return date.formatted(.dateTime.day().month(.abbreviated))
        case .numeric: return date.formatted(date: .numeric, time: .omitted)
        }
    }

    /// The whole date and time, for a tooltip.
    static func full(_ date: Date) -> String { date.formatted(date: .complete, time: .shortened) }
}
