import Foundation

/// Reads timer requests: "5m tea", "timer 10 min", "10 minute timer",
/// "remind me in 20 minutes to call Sam", "in 1h 30m stretch", "90s".
public struct TimerQuery: Equatable, Sendable {
    public let seconds: Int
    public let label: String

    public init(seconds: Int, label: String) { self.seconds = seconds; self.label = label }

    public static let maximumSeconds = 24 * 60 * 60

    public static func parse(_ text: String) -> TimerQuery? {
        var words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        var explicit = false
        // Leading intent words.
        let leading: Set<String> = ["timer", "set", "start", "a", "remind", "me", "in", "for"]
        while let first = words.first, leading.contains(first) {
            if ["timer", "remind"].contains(first) { explicit = true }
            words.removeFirst()
        }
        var seconds = 0
        var index = 0
        var sawDuration = false
        var spacedShortUnit = false
        while index < words.count {
            let word = words[index]
            if let value = compact(word) {
                seconds += value; sawDuration = true; index += 1; continue
            }
            if let number = Double(word), index + 1 < words.count, let unit = unitSeconds(words[index + 1]) {
                if words[index + 1].count == 1 { spacedShortUnit = true }
                seconds += Int(number * Double(unit)); sawDuration = true; index += 2; continue
            }
            if sawDuration, word == "and" { index += 1; continue }
            break
        }
        guard sawDuration, seconds > 0, seconds <= maximumSeconds else { return nil }
        var rest = Array(words[index...])
        if rest.first == "timer" { explicit = true; rest.removeFirst() }
        // "10 m in ft" is a conversion, not a timer.
        if !explicit, spacedShortUnit || ["in", "to", "into", "as"].contains(rest.first ?? "") { return nil }
        while let first = rest.first, ["to", "for", "then", "-", "–"].contains(first) { rest.removeFirst() }
        let original = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let label = original.suffix(rest.count).joined(separator: " ")
        return TimerQuery(seconds: seconds, label: label)
    }

    /// "1 h 30 min", "5 min", "45 s".
    public static func describe(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, secs = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if secs > 0 { parts.append("\(secs) s") }
        return parts.joined(separator: " ")
    }

    /// "5m", "1h30m", "90s", "2hr".
    private static func compact(_ word: String) -> Int? {
        var total = 0, digits = "", matched = false
        var rest = Substring(word)
        while !rest.isEmpty {
            digits = String(rest.prefix { $0.isNumber || $0 == "." })
            guard !digits.isEmpty, let number = Double(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            let unitText = String(rest.prefix { $0.isLetter })
            guard let unit = unitSeconds(unitText) else { return nil }
            rest = rest.dropFirst(unitText.count)
            total += Int(number * Double(unit)); matched = true
        }
        return matched ? total : nil
    }

    private static func unitSeconds(_ word: String) -> Int? {
        switch word {
        case "s", "sec", "secs", "second", "seconds": return 1
        case "m", "min", "mins", "minute", "minutes": return 60
        case "h", "hr", "hrs", "hour", "hours": return 3600
        default: return nil
        }
    }
}
