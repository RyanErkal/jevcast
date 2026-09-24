import Foundation

/// Converts a clock time between places: "6pm atlanta time in uk time", "3pm uk in pst", "now in tokyo".
/// Foundation does the zone math, so daylight saving time is always current.
public enum TimeZoneQuery {
    /// A time of day as typed. `isNow` means the current moment.
    public struct Clock: Equatable, Sendable {
        public let hour: Int
        public let minute: Int
        public let isNow: Bool
        /// "18:00" answers in 24-hour time; "6pm" answers in 12-hour time.
        public let twentyFourHour: Bool

        public static let now = Clock(hour: 0, minute: 0, isNow: true, twentyFourHour: false)
    }

    public struct Answer: Equatable, Sendable {
        /// The converted time, which Return copies: "11:00 PM IST".
        public let title: String
        /// Both sides and the gap: "6:00 PM EDT Atlanta → Ireland · 5h ahead".
        public let detail: String
    }

    private static let connectors = [" in ", " to ", " into ", " for ", " as ", " -> ", " → "]

    /// The local answer, or nil when the text is not a clear time conversion.
    public static func evaluate(_ text: String, now: Date = Date(), local: TimeZone = .current) -> Answer? {
        let lower = normalized(text)
        // Every split is tried, last first, so "3pm in london in tokyo" and "time in tokyo" both work.
        var searchEnd = lower.endIndex
        while let range = lower.range(of: " ", options: .backwards, range: lower.startIndex..<searchEnd) {
            searchEnd = range.lowerBound
            for connector in connectors {
                guard lower[range.lowerBound...].hasPrefix(connector) else { continue }
                let left = String(lower[..<range.lowerBound]), right = String(lower[lower.index(range.lowerBound, offsetBy: connector.count)...])
                guard let target = TimeZonePlaces.place(right), let (clock, sourceText) = leadingClock(left) else { continue }
                let source: TimeZonePlace?
                if sourceText.isEmpty { source = nil } else {
                    guard let named = TimeZonePlaces.place(sourceText) else { continue }
                    source = named
                }
                return convert(clock, from: source, to: target, now: now, local: local)
            }
        }
        return nil
    }

    /// The first clock time anywhere in the text, for Jev to work with. Nil when there is none.
    public static func clock(in text: String) -> Clock? {
        let words = normalized(text).split(separator: " ").map(String.init)
        for start in words.indices {
            for length in [2, 1] where start + length <= words.count {
                let piece = words[start..<start + length].joined(separator: " ")
                if let clock = parseClock(piece) { return clock }
            }
        }
        return nil
    }

    /// Converts a clock time from one place to another. A nil place is the Mac's own time zone.
    public static func convert(_ clock: Clock, from source: TimeZonePlace?, to target: TimeZonePlace?, now: Date = Date(), local: TimeZone = .current) -> Answer? {
        guard let sourceZone = source.map(\.timeZone) ?? local, let targetZone = target.map(\.timeZone) ?? local,
              source != nil || target != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceZone
        let moment: Date
        var shifted = false
        if clock.isNow {
            moment = now
        } else {
            // Today in the source place. A time that the clock change skips moves to the next real time.
            guard let date = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: now,
                                           matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { return nil }
            moment = date
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            shifted = parts.hour != clock.hour || parts.minute != clock.minute
        }
        let targetTime = format(moment, zone: targetZone, twentyFourHour: clock.twentyFourHour)
        let sourceTime = format(moment, zone: sourceZone, twentyFourHour: clock.twentyFourHour)
        var title = targetTime + " " + TimeZonePlaces.label(targetZone, at: moment)
        let dayShift = dayDifference(moment, from: sourceZone, to: targetZone)
        if dayShift > 0 { title += " (next day)" } else if dayShift < 0 { title += " (previous day)" }

        let sourceName = source?.name ?? "Here"
        let targetName = target?.name ?? "here"
        var detail = sourceTime + " " + TimeZonePlaces.label(sourceZone, at: moment) + " " + sourceName + " → " + targetName
        detail += " · " + gap(targetZone.secondsFromGMT(for: moment) - sourceZone.secondsFromGMT(for: moment))
        let notes = [source?.note, target?.note, shifted ? "clock change: time moved forward" : nil].compactMap { $0 }
        if !notes.isEmpty { detail += " · " + notes.joined(separator: ", ") }
        return Answer(title: title, detail: detail)
    }

    // MARK: Parsing

    private static func normalized(_ text: String) -> String {
        var lower = text.lowercased()
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: "a.m.", with: "am")
            .replacingOccurrences(of: "p.m.", with: "pm")
        if lower.hasPrefix("what time is it ") { lower = "now " + lower.dropFirst(16) }
        for lead in ["what time is ", "what's ", "whats ", "what is ", "convert "] where lower.hasPrefix(lead) {
            lower.removeFirst(lead.count)
        }
        return lower.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "6pm atlanta time" → (6 PM, "atlanta time"). Also "atlanta 6pm". The rest may be empty.
    private static func leadingClock(_ text: String) -> (Clock, String)? {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        for length in [2, 1] where length <= words.count {
            if let clock = parseClock(words.prefix(length).joined(separator: " ")) {
                return (clock, words.dropFirst(length).joined(separator: " "))
            }
            if let clock = parseClock(words.suffix(length).joined(separator: " ")) {
                return (clock, words.dropLast(length).joined(separator: " "))
            }
        }
        return nil
    }

    /// "6pm", "6 pm", "6:30pm", "18:00", "noon", "midnight", "now". A bare "6" is not a time.
    static func parseClock(_ text: String) -> Clock? {
        switch text {
        case "now", "time", "the time", "current time": return .now
        case "noon", "midday": return Clock(hour: 12, minute: 0, isNow: false, twentyFourHour: false)
        case "midnight": return Clock(hour: 0, minute: 0, isNow: false, twentyFourHour: false)
        default: break
        }
        var body = text.replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where body.hasSuffix(suffix) {
            meridiem = suffix; body.removeLast(2)
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts[0].count <= 2, let hour = Int(parts[0]) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let value = Int(parts[1]), value < 60 else { return nil }
            minute = value
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            let converted = hour % 12 + (meridiem == "pm" ? 12 : 0)
            return Clock(hour: converted, minute: minute, isNow: false, twentyFourHour: false)
        }
        // Without am or pm, only "18:00" style is a time.
        guard parts.count == 2, hour < 24 else { return nil }
        return Clock(hour: hour, minute: minute, isNow: false, twentyFourHour: true)
    }

    // MARK: Formatting

    private static func format(_ date: Date, zone: TimeZone, twentyFourHour: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = twentyFourHour ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    private static func dayDifference(_ date: Date, from source: TimeZone, to target: TimeZone) -> Int {
        func day(_ zone: TimeZone) -> DateComponents {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            return calendar.dateComponents([.year, .month, .day], from: date)
        }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        guard let a = utc.date(from: day(source)), let b = utc.date(from: day(target)) else { return 0 }
        return utc.dateComponents([.day], from: a, to: b).day ?? 0
    }

    private static func gap(_ seconds: Int) -> String {
        guard seconds != 0 else { return "same time" }
        let hours = abs(seconds) / 3600, minutes = abs(seconds) % 3600 / 60
        let amount = minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        return amount + (seconds > 0 ? " ahead" : " behind")
    }
}
