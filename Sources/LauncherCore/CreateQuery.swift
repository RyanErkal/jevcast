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

    private static let reminderPrefixes = ["remind me to ", "remind me about ", "remind me ", "add reminder ", "new reminder ", "reminder: ", "reminder "]
    private static let eventPrefixes = ["add event ", "new event ", "create event ", "add meeting ", "schedule ", "event: ", "event "]

    public static func parse(_ text: String, now: Date = Date()) -> CreateQuery? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        let kind: Kind, body: String
        if let prefix = reminderPrefixes.first(where: { lower.hasPrefix($0) }) {
            kind = .reminder; body = String(trimmed.dropFirst(prefix.count))
        } else if let prefix = eventPrefixes.first(where: { lower.hasPrefix($0) }) {
            kind = .event; body = String(trimmed.dropFirst(prefix.count))
        } else { return nil }
        let (title, date) = extractDate(from: body, now: now)
        let cleaned = tidy(title)
        guard !cleaned.isEmpty else { return nil }
        // An event needs a day or a time, so "schedule backups" stays a search.
        if kind == .event && date == nil { return nil }
        return CreateQuery(kind: kind, title: cleaned, date: date, hasTime: date != nil && mentionsTime(body))
    }

    /// The first date in the text and the text without it.
    static func extractDate(from text: String, now: Date) -> (String, Date?) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return (text, nil) }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range), var date = match.date,
              let found = Range(match.range, in: text) else { return (text, nil) }
        // A time already past today, with no day named, means the next one.
        if date < now, !mentionsDay(String(text[found])), let next = Calendar.current.date(byAdding: .day, value: 1, to: date) { date = next }
        var rest = text
        rest.removeSubrange(found)
        return (rest, date)
    }

    static func mentionsTime(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["noon", "midnight", "morning", "afternoon", "evening", "tonight"].contains(where: lower.contains) { return true }
        return lower.range(of: #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b|\b\d{1,2}:\d{2}\b|\bat \d{1,2}\b|\bin \d+ ?(min|minute|minutes|hour|hours|h)\b"#, options: .regularExpression) != nil
    }

    static func mentionsDay(_ text: String) -> Bool {
        let lower = text.lowercased()
        let days = ["today", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "next", "week", "in "]
        return days.contains(where: lower.contains) || lower.contains(where: \.isNumber) && lower.contains("/")
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
