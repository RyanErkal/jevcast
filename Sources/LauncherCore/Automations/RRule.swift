import Foundation

/// The RFC 5545 subset automations use: FREQ=HOURLY|DAILY|WEEKLY, INTERVAL, BYDAY, BYHOUR, BYMINUTE.
public struct RRule: Equatable, Sendable {
    public enum Frequency: String, Sendable { case hourly = "HOURLY", daily = "DAILY", weekly = "WEEKLY" }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case malformedPart(String)
        case unsupportedPart(String)
        case duplicatePart(String)
        case missingFrequency
        case invalidValue(part: String, value: String)
        public var description: String {
            switch self {
            case .empty: return "The rule is empty."
            case .malformedPart(let p): return "\"\(p)\" is not NAME=VALUE."
            case .unsupportedPart(let p): return "\(p) is not supported."
            case .duplicatePart(let p): return "\(p) appears twice."
            case .missingFrequency: return "FREQ is missing."
            case .invalidValue(let part, let value): return "\"\(value)\" is not a valid \(part)."
            }
        }
    }

    public var frequency: Frequency
    public var interval: Int
    /// Calendar weekdays, 1 = Sunday ... 7 = Saturday. Sorted, unique. Empty means every day.
    public var weekdays: [Int]
    /// Sorted, unique. Empty means the anchor's hour (daily/weekly).
    public var hours: [Int]
    /// Sorted, unique. Empty means the anchor's minute.
    public var minutes: [Int]

    static let dayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
    static let maxInterval = 1000

    public init(_ text: String) throws {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.uppercased().hasPrefix("RRULE:") { body = String(body.dropFirst(6)) }
        guard !body.isEmpty else { throw ParseError.empty }
        var seen = Set<String>()
        var freq: Frequency?
        var interval = 1, days: [Int] = [], hours: [Int] = [], minutes: [Int] = []
        for raw in body.split(separator: ";", omittingEmptySubsequences: false) {
            let part = String(raw)
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { throw ParseError.malformedPart(part) }
            let name = pieces[0].uppercased(), value = String(pieces[1])
            guard seen.insert(name).inserted else { throw ParseError.duplicatePart(name) }
            switch name {
            case "FREQ":
                guard let f = Frequency(rawValue: value.uppercased()) else { throw ParseError.invalidValue(part: name, value: value) }
                freq = f
            case "INTERVAL":
                guard let n = Int(value), n > 0, n <= Self.maxInterval else { throw ParseError.invalidValue(part: name, value: value) }
                interval = n
            case "BYDAY":
                days = try value.split(separator: ",", omittingEmptySubsequences: false).map {
                    guard let d = Self.dayCodes[$0.uppercased()] else { throw ParseError.invalidValue(part: name, value: String($0)) }
                    return d
                }
            case "BYHOUR": hours = try Self.numbers(value, part: name, range: 0...23)
            case "BYMINUTE": minutes = try Self.numbers(value, part: name, range: 0...59)
            default: throw ParseError.unsupportedPart(name)
            }
        }
        guard let freq else { throw ParseError.missingFrequency }
        // Hourly steps by elapsed time from the anchor, so wall-time filters would be ignored. Refuse them.
        if freq == .hourly, !(days.isEmpty && hours.isEmpty && minutes.isEmpty) { throw ParseError.unsupportedPart("BYDAY/BYHOUR/BYMINUTE with HOURLY") }
        self.frequency = freq; self.interval = interval
        self.weekdays = Array(Set(days)).sorted(); self.hours = Array(Set(hours)).sorted(); self.minutes = Array(Set(minutes)).sorted()
    }

    private static func numbers(_ value: String, part: String, range: ClosedRange<Int>) throws -> [Int] {
        try value.split(separator: ",", omittingEmptySubsequences: false).map {
            guard let n = Int($0), range.contains(n) else { throw ParseError.invalidValue(part: part, value: String($0)) }
            return n
        }
    }

    /// The canonical text, without the "RRULE:" prefix.
    public var text: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        if !weekdays.isEmpty {
            let order = [2, 3, 4, 5, 6, 7, 1]
            let codes = Dictionary(uniqueKeysWithValues: Self.dayCodes.map { ($1, $0) })
            parts.append("BYDAY=" + order.filter(weekdays.contains).compactMap { codes[$0] }.joined(separator: ","))
        }
        if !hours.isEmpty { parts.append("BYHOUR=" + hours.map(String.init).joined(separator: ",")) }
        if !minutes.isEmpty { parts.append("BYMINUTE=" + minutes.map(String.init).joined(separator: ",")) }
        return parts.joined(separator: ";")
    }
}
