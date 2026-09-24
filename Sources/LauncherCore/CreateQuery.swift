import Foundation

/// "remind me to call mum at 5pm" and "add event lunch with Sam friday 1pm":
/// a request to make a reminder or a calendar event, with the date read from the text.
public struct CreateQuery: Equatable, Sendable {
    public enum Kind: Sendable { case reminder, event }
    public let kind: Kind
    public let title: String
    /// Nil for a reminder with no date. An event with no date starts at the next full hour.
    public let date: Date?
    /// False when the text named a day but no time, such as "tomorrow".
    public let hasTime: Bool
    public init(kind: Kind, title: String, date: Date?, hasTime: Bool) {
        self.kind = kind; self.title = title; self.date = date; self.hasTime = hasTime
    }

    /// Prefixes that clearly ask for a reminder, and ones that also need a date ("reminder app" stays a search).
    private static let reminderPrefixes: [(prefix: String, needsDate: Bool)] = [
        ("remind me to ", false), ("remind me about ", false), ("add reminder ", false), ("new reminder ", false),
        ("reminder: ", false), ("remind me ", true), ("reminder ", true)
    ]
    private static let eventPrefixes = ["add event ", "new event ", "create event ", "add meeting ", "schedule ", "event: ", "event "]

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> CreateQuery? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        let kind: Kind, body: String, needsDate: Bool
        if let match = reminderPrefixes.first(where: { lower.hasPrefix($0.prefix) }) {
            kind = .reminder; body = String(trimmed.dropFirst(match.prefix.count)); needsDate = match.needsDate
        } else if let prefix = eventPrefixes.first(where: { lower.hasPrefix($0) }) {
            // An event needs a day or a time, so "schedule backups" stays a search.
            kind = .event; body = String(trimmed.dropFirst(prefix.count)); needsDate = true
        } else { return nil }
        let found = extractDate(from: body, now: now, calendar: calendar)
        let cleaned = tidy(found.rest)
        guard !cleaned.isEmpty, !(needsDate && found.date == nil) else { return nil }
        return CreateQuery(kind: kind, title: cleaned, date: found.date, hasTime: found.hasTime)
    }

    /// The first date in the text, whether it named a time, and the text without it.
    static func extractDate(from text: String, now: Date, calendar: Calendar) -> (rest: String, date: Date?, hasTime: Bool) {
        // "in 20 minutes", "in an hour", "in half an hour": NSDataDetector misses these.
        let relative = #"\bin (\d+|an?|half an) ?(minutes?|mins?|m|hours?|hrs?|h)\b"#
        if let range = text.range(of: relative, options: [.regularExpression, .caseInsensitive]) {
            let phrase = text[range].lowercased()
            // "in 20m" and "in 2h" have no space between the number and the unit.
            let amount = Double(phrase.filter(\.isNumber)) ?? (phrase.contains("half") ? 0.5 : 1)
            let hours = phrase.range(of: #"(hours?|hrs?|h)$"#, options: .regularExpression) != nil
            let seconds = amount * (hours ? 3600 : 60)
            var rest = text; rest.removeSubrange(range)
            return (rest, now.addingTimeInterval(seconds), true)
        }
        // Meal words read as times ("lunch" is 12:00), so they are hidden from the detector.
        var protected = text
        for word in ["breakfast", "brunch", "lunch", "dinner", "supper"] {
            while let range = protected.range(of: word, options: .caseInsensitive) {
                protected.replaceSubrange(range, with: String(repeating: "q", count: protected.distance(from: range.lowerBound, to: range.upperBound)))
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: protected, options: [], range: NSRange(protected.startIndex..., in: protected)),
           var date = match.date, let found = Range(match.range, in: text) {
            let phrase = String(text[found])
            if date < now {
                // A time with no day means the next one; a past day and month means next year.
                if !mentionsDay(phrase) { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
                else if mentionsMonthOrDate(phrase) {
                    while date < now, let next = calendar.date(byAdding: .year, value: 1, to: date) { date = next }
                }
            }
            var rest = text; rest.removeSubrange(found)
            return (rest, date, mentionsTime(phrase))
        }
        // "at 9" or "at 9:30" with no am or pm: the next time the clock shows it.
        if let range = text.range(of: #"\bat (\d{1,2})(:(\d{2}))?\b"#, options: .regularExpression) {
            let parts = text[range].dropFirst(3).split(separator: ":").compactMap { Int($0) }
            if let hour = parts.first, (0...23).contains(hour) {
                let minute = parts.count > 1 ? min(parts[1], 59) : 0
                let hours = hour < 12 && hour > 0 ? [hour, hour + 12] : [hour]
                let today = calendar.startOfDay(for: now)
                let candidates = (0...1).flatMap { offset in hours.compactMap { h -> Date? in
                    guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
                    return calendar.date(bySettingHour: h, minute: minute, second: 0, of: day)
                } }
                if let next = candidates.filter({ $0 > now }).min() {
                    var rest = text; rest.removeSubrange(range)
                    return (rest, next, true)
                }
            }
        }
        return (text, nil, false)
    }

    static func mentionsTime(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["noon", "midnight", "morning", "afternoon", "evening", "tonight"].contains(where: lower.contains) { return true }
        return lower.range(of: #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b|\b\d{1,2}:\d{2}\b|\bat \d{1,2}\b|\bin \d+ ?(min|minute|minutes|hour|hours|h)\b"#, options: .regularExpression) != nil
    }

    static func mentionsDay(_ text: String) -> Bool {
        let lower = text.lowercased()
        let days = ["today", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "next", "week", "in "]
        return days.contains(where: lower.contains) || mentionsMonthOrDate(text)
    }

    static func mentionsMonthOrDate(_ text: String) -> Bool {
        let lower = text.lowercased()
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if months.contains(where: { lower.range(of: "\\b" + $0, options: .regularExpression) != nil }) { return true }
        return lower.range(of: #"\d{1,2}[/.-]\d{1,2}|\d{1,2}(st|nd|rd|th)\b"#, options: .regularExpression) != nil
    }

    /// Drops words the date left behind: "call mum at" becomes "call mum".
    static func tidy(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let dangling: Set<String> = ["at", "on", "by", "for", "in", "from", "this", "next", "the", "to"]
        while let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, ["to", "on", "at"].contains(first.lowercased()) { words.removeFirst() }
        let joined = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}
