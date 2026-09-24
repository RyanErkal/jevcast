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
        /// Both sides, the day, and the gap: "6:00 PM EDT Atlanta → Ireland · 5h ahead".
        public let detail: String
    }

    private static let connectors = [" in ", " to ", " into ", " for ", " as ", " -> ", " → "]
    /// Targets that mean the Mac's own time zone.
    private static let localNames: Set<String> = ["me", "here", "local", "local time", "my time", "mine", "my timezone", "my time zone", "our time"]
    /// Words that say a different day or a later moment. The answer would need a date, so there is none.
    private static let relativeWords: Set<String> = ["tomorrow", "yesterday", "tonight", "later", "ago", "hours", "hour", "minutes", "mins", "hrs",
                                                     "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "next", "last"]

    /// The local answer, or nil when the text is not a clear time conversion.
    public static func evaluate(_ text: String, now: Date = Date(), local: TimeZone = .current) -> Answer? {
        let lower = normalized(text)
        guard !lower.split(separator: " ").contains(where: { relativeWords.contains(String($0)) }) else { return nil }
        // Every split is tried, last first, so "3pm in london in tokyo" and "time in tokyo" both work.
        var searchEnd = lower.endIndex
        while let range = lower.range(of: " ", options: .backwards, range: lower.startIndex..<searchEnd) {
            searchEnd = range.lowerBound
            for connector in connectors where lower[range.lowerBound...].hasPrefix(connector) {
                let left = String(lower[..<range.lowerBound])
                let right = String(lower[lower.index(range.lowerBound, offsetBy: connector.count)...])
                guard let (clock, sourceText) = leadingClock(left) else { continue }
                // "time to christmas" is not a conversion: the current time needs "in".
                if clock.isNow && connector != " in " { continue }
                let target: TimeZonePlace?
                if localNames.contains(right) { target = nil } else {
                    guard let named = TimeZonePlaces.place(right) else { continue }
                    target = named
                }
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

    /// A clock time anywhere in the text, for Jev to work with. `now` and `time` count only when
    /// `explicitOnly` is false. Nil when there is none, or when the text names another day.
    public static func clock(in text: String, explicitOnly: Bool = false) -> Clock? {
        let words = normalized(text).split(separator: " ").map(String.init)
        guard !words.contains(where: relativeWords.contains) else { return nil }
        for start in words.indices {
            for length in [2, 1] where start + length <= words.count {
                let piece = words[start..<start + length].joined(separator: " ")
                if let clock = parseClock(piece), !(explicitOnly && clock.isNow) { return clock }
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
        var notes: [String] = []
        if clock.isNow {
            moment = now
        } else {
            // Today in the source place. A time that the clock change skips moves to the next real time.
            guard let date = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: now,
                                           matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { return nil }
            moment = date
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            if parts.hour != clock.hour || parts.minute != clock.minute {
                notes.append("clocks change today: time moved forward")
            } else if calendar.dateComponents([.hour, .minute], from: date.addingTimeInterval(3600)) == parts {
                notes.append("clocks change today: this time happens twice, the first is used")
            }
        }
        let sourceID = source?.zone ?? local.identifier, targetID = target?.zone ?? local.identifier
        let title = format(moment, zone: targetZone, twentyFourHour: clock.twentyFourHour) + " " + TimeZonePlaces.label(targetZone, id: targetID, at: moment)
        var detail = format(moment, zone: sourceZone, twentyFourHour: clock.twentyFourHour) + " " + TimeZonePlaces.label(sourceZone, id: sourceID, at: moment)
        detail += " " + (source?.name ?? "Here") + " → " + (target?.name ?? "here")
        let dayShift = dayDifference(moment, from: sourceZone, to: targetZone)
        if dayShift > 0 { detail += " · next day" } else if dayShift < 0 { detail += " · previous day" }
        detail += " · " + gap(targetZone.secondsFromGMT(for: moment) - sourceZone.secondsFromGMT(for: moment))
        notes = [source?.note, target?.note].compactMap { $0 } + notes
        for place in [source, target].compactMap({ $0 }) {
            // "pst" in September: the zone is on summer time, so say which one was used.
            if let fixed = place.abbreviation, let zone = place.timeZone, zone.secondsFromGMT(for: moment) != fixed.offset {
                notes.append(fixed.text + " read as " + place.name + " (" + TimeZonePlaces.label(zone, id: place.zone, at: moment) + " now)")
            }
        }
        if !notes.isEmpty { detail += " · " + notes.joined(separator: ", ") }
        return Answer(title: title, detail: detail)
    }

    // MARK: Parsing

    private static func normalized(_ text: String) -> String {
        var lower = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: "a.m.", with: "am")
            .replacingOccurrences(of: "p.m.", with: "pm")
        lower = lower.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if lower.hasPrefix("what time is it ") { lower = "now " + lower.dropFirst(16) }
        for lead in ["what time is ", "what's ", "whats ", "what is ", "convert "] where lower.hasPrefix(lead) {
            lower.removeFirst(lead.count)
        }
        return lower
    }

    /// Words around a place that carry no meaning: "6pm from london", "3pm in london in tokyo".
    private static let fillers: Set<String> = ["now", "right", "current", "from", "in", "at", "the"]

    /// "6pm atlanta time" → (6 PM, "atlanta time"). Also "atlanta 6pm". The rest may be empty.
    private static func leadingClock(_ text: String) -> (Clock, String)? {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        func rest(_ slice: ArraySlice<String>) -> String {
            var slice = slice
            while let first = slice.first, fillers.contains(first) { slice.removeFirst() }
            while let last = slice.last, fillers.contains(last) { slice.removeLast() }
            return slice.joined(separator: " ")
        }
        for length in [4, 3, 2, 1] where length <= words.count {
            if let clock = parseClock(words.prefix(length).joined(separator: " ")) { return (clock, rest(words.dropFirst(length))) }
            if let clock = parseClock(words.suffix(length).joined(separator: " ")) { return (clock, rest(words.dropLast(length))) }
        }
        return nil
    }

    private static let nowPhrases: Set<String> = [
        "now", "time", "the time", "current time", "the current time", "time now", "the time now",
        "right now", "time right now", "the time right now", "now now"
    ]

    /// "6pm", "6 pm", "6:30pm", "6.30pm", "18:00", "noon", "midnight", "now". A bare "6" is not a time.
    static func parseClock(_ text: String) -> Clock? {
        if nowPhrases.contains(text) { return .now }
        switch text {
        case "noon", "midday": return Clock(hour: 12, minute: 0, isNow: false, twentyFourHour: false)
        case "midnight": return Clock(hour: 0, minute: 0, isNow: false, twentyFourHour: false)
        default: break
        }
        var body = text.replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where body.hasSuffix(suffix) {
            meridiem = suffix; body.removeLast(2)
        }
        // "6.30pm" is common in the UK and Ireland. Without am or pm, "6.30" stays a number.
        if meridiem != nil { body = body.replacingOccurrences(of: ".", with: ":") }
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
