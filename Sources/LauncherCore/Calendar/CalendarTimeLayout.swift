import Foundation

/// A wall-clock grid. Its height stays at 24 hours on daylight-saving days.
public enum CalendarTimeLayout {
    public struct Item: Equatable, Sendable {
        public let id: String
        public let start: Date
        public let end: Date
        public init(id: String, start: Date, end: Date) { self.id = id; self.start = start; self.end = end }
    }
    public struct Placement: Equatable, Sendable {
        public let id: String
        public let startMinute: Double
        public let endMinute: Double
        public let column: Int
        public let columns: Int
    }
    public static func minute(_ date: Date, on day: Date, calendar: Calendar) -> Double {
        if date <= calendar.startOfDay(for: day) { return 0 }
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        if date >= next { return 1440 }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
    }

    public static func placements(_ events: [Item], on day: Date, calendar: Calendar = .current, minimumMinutes: Double = 25) -> [Placement] {
        let first = calendar.startOfDay(for: day), last = calendar.date(byAdding: .day, value: 1, to: first)!
        struct Span { let id: String; let start: Double; let end: Double }
        let spans = events.filter { $0.start < last && $0.end > first }.map {
            let start = minute($0.start, on: day, calendar: calendar)
            let end = max(start + minimumMinutes, minute($0.end, on: day, calendar: calendar))
            return Span(id: $0.id, start: start, end: end)
        }.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        var result: [Placement] = [], group: [(Span, Int)] = [], columnEnds: [Double] = [], groupEnd = 0.0
        func finish() {
            let columns = columnEnds.count
            result += group.map { Placement(id: $0.0.id, startMinute: $0.0.start, endMinute: $0.0.end, column: $0.1, columns: columns) }
            group = []; columnEnds = []
        }
        for span in spans {
            if !group.isEmpty && span.start >= groupEnd { finish() }
            let column = columnEnds.firstIndex(where: { $0 <= span.start }) ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(span.end) } else { columnEnds[column] = span.end }
            group.append((span, column)); groupEnd = max(groupEnd, span.end)
        }
        finish()
        return result
    }
}
