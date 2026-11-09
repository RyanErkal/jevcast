import Foundation

/// Decides which events get a notice shortly before they start. Each start is announced once.
public enum MeetingAlert {
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let start: Date
        public let allDay: Bool
        public init(id: String, start: Date, allDay: Bool) { self.id = id; self.start = start; self.allDay = allDay }
        /// One announcement per event and start time, so a moved meeting is announced again.
        public var key: String { id + "@" + String(Int(start.timeIntervalSince1970)) }
    }

    /// Events that start within `lead` seconds, or started less than a minute ago, and were not announced.
    public static func due(_ events: [Candidate], now: Date, lead: TimeInterval = 300, announced: Set<String>) -> [Candidate] {
        var seen = announced
        return events.filter { event in
            guard !event.allDay else { return false }
            let wait = event.start.timeIntervalSince(now)
            return wait <= lead && wait > -60 && seen.insert(event.key).inserted
        }
        .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// "Starts in 4 min", "Starts now".
    public static func when(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "Starts now" : "Starts in \(minutes) min"
    }
}
