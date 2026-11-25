import Foundation

/// A quiet label above a run of rows in a mail list sorted newest first.
public enum MailDateSection: Hashable, Sendable {
    case today, yesterday, thisWeek, lastWeek
    /// A month of the current year, 1 to 12.
    case month(Int)
    /// Any earlier year.
    case year(Int)

    /// "Today", "Last Week", "October", or "2025". Month names come from the calendar's locale.
    public func title(calendar: Calendar = .current) -> String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .lastWeek: return "Last Week"
        case .month(let month):
            let names = calendar.standaloneMonthSymbols
            return names.indices.contains(month - 1) ? names[month - 1] : String(month)
        case .year(let year): return String(year)
        }
    }
}

/// Groups a mail list by date: Today, Yesterday, This Week, Last Week, then each month of this
/// year by name, then each earlier year. The week starts on the calendar's own first weekday.
public enum MailDateSections {
    /// A shorter list shows no labels: they would take more room than they save.
    public static let minimumRows = 8

    /// The edges of each section for one `now`, worked out once for a whole list.
    public struct Edges: Sendable {
        let today: Date
        let yesterday: Date
        let thisWeek: Date
        let lastWeek: Date
        let year: Int
        let calendar: Calendar

        public init(now: Date, calendar: Calendar) {
            self.calendar = calendar
            today = calendar.startOfDay(for: now)
            yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
            year = calendar.component(.year, from: now)
        }

        public func section(for date: Date) -> MailDateSection {
            // A date after now, such as from a wrong clock, counts as today.
            if date >= today { return .today }
            if date >= yesterday { return .yesterday }
            if date >= thisWeek { return .thisWeek }
            if date >= lastWeek { return .lastWeek }
            let year = calendar.component(.year, from: date)
            return year == self.year ? .month(calendar.component(.month, from: date)) : .year(year)
        }
    }

    public static func section(for date: Date, now: Date, calendar: Calendar) -> MailDateSection {
        Edges(now: now, calendar: calendar).section(for: date)
    }

    /// The rows where a section starts, by row index. Empty when the list has fewer than
    /// `minimumRows` rows or is not sorted newest first, such as results ranked another way.
    public static func starts(_ dates: [Date], now: Date, calendar: Calendar) -> [Int: MailDateSection] {
        guard dates.count >= minimumRows, zip(dates, dates.dropFirst()).allSatisfy({ $0 >= $1 }) else { return [:] }
        let edges = Edges(now: now, calendar: calendar)
        var result: [Int: MailDateSection] = [:]
        var current: MailDateSection?
        for (index, date) in dates.enumerated() {
            let section = edges.section(for: date)
            if section != current { result[index] = section; current = section }
        }
        return result
    }
}
