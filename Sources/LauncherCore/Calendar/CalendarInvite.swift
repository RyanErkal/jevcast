import Foundation

/// A meeting invitation carried in a message as iCalendar text (RFC 5545), and the reply that
/// answers it (RFC 5546, sent by mail as RFC 6047 describes). The text is data only: nothing in it
/// is run, fetched, or followed.
public struct CalendarInvite: Equatable, Sendable {
    public enum Method: String, Sendable { case request = "REQUEST", cancel = "CANCEL", reply = "REPLY", publish = "PUBLISH", other = "" }
    public enum Response: String, Sendable, CaseIterable {
        case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED"
        public var verb: String {
            switch self {
            case .accepted: return "Accepted"
            case .tentative: return "Tentative"
            case .declined: return "Declined"
            }
        }
    }
    public struct Person: Equatable, Sendable {
        public let name: String
        public let address: String
        /// `ACCEPTED`, `DECLINED`, `TENTATIVE`, `NEEDS-ACTION`, or empty.
        public let status: String
    }

    public let method: Method
    public let uid: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let location: String
    public let notes: String
    public let organizer: Person?
    public let attendees: [Person]
    public let sequence: Int
    public let recurring: Bool
    /// The event's own time zone, when the invitation names one this Mac knows.
    public let timeZone: String?
    /// The `DTSTART`, `DTEND`, `RECURRENCE-ID`, and `ORGANIZER` lines as sent, for the reply.
    let echoed: [String]

    /// Reads the first event of the text. Nil when there is none or it has no identifier or start.
    public static func parse(_ text: String) -> CalendarInvite? {
        guard text.utf8.count <= 1_000_000 else { return nil }
        let lines = unfold(text)
        var method = Method.other
        var inEvent = false, depth = 0
        var properties: [(name: String, params: [String: String], value: String, raw: String)] = []
        for line in lines {
            guard let property = property(line) else { continue }
            if property.name == "BEGIN" {
                if property.value.uppercased() == "VEVENT", !inEvent, properties.isEmpty { inEvent = true; depth = 0 } else if inEvent { depth += 1 }
                continue
            }
            if property.name == "END" {
                if inEvent, depth == 0, property.value.uppercased() == "VEVENT" { break }
                if inEvent { depth = max(0, depth - 1) }
                continue
            }
            if !inEvent, property.name == "METHOD" { method = Method(rawValue: property.value.uppercased()) ?? .other }
            // Alarms and other parts nested in the event are not the event's own properties.
            if inEvent, depth == 0 { properties.append((property.name, property.params, property.value, line)) }
        }
        func first(_ name: String) -> (name: String, params: [String: String], value: String, raw: String)? { properties.first { $0.name == name } }
        guard let uid = first("UID")?.value, !uid.isEmpty, uid.count <= 1024, let startLine = first("DTSTART"),
              let start = date(startLine.value, params: startLine.params) else { return nil }
        let allDay = startLine.params["VALUE"]?.uppercased() == "DATE" || startLine.value.count == 8
        var end = first("DTEND").flatMap { date($0.value, params: $0.params) }
        if end == nil, let length = first("DURATION").flatMap({ duration($0.value) }) { end = start.addingTimeInterval(length) }
        let finish = end ?? start.addingTimeInterval(allDay ? 86_400 : 3600)
        let attendees = properties.filter { $0.name == "ATTENDEE" }.prefix(500).compactMap { person($0.value, $0.params) }
        let echoed = ["DTSTART", "DTEND", "RECURRENCE-ID", "ORGANIZER"].compactMap { first($0)?.raw }
        let zone = startLine.params["TZID"].flatMap(timeZone)?.identifier
        return CalendarInvite(method: method, uid: uid, title: unescape(first("SUMMARY")?.value ?? ""), start: start, end: max(finish, start),
                              allDay: allDay, location: unescape(first("LOCATION")?.value ?? ""), notes: unescape(first("DESCRIPTION")?.value ?? ""),
                              organizer: first("ORGANIZER").flatMap { person($0.value, $0.params) }, attendees: Array(attendees),
                              sequence: max(0, Int(first("SEQUENCE")?.value ?? "") ?? 0),
                              recurring: first("RRULE") != nil || first("RECURRENCE-ID") != nil, timeZone: zone, echoed: echoed)
    }

    /// The attendee among `addresses`: the person the invitation asks. Addresses compare without case.
    public func attendee(among addresses: [String]) -> Person? {
        let own = Set(addresses.map { $0.lowercased() })
        return attendees.first { own.contains($0.address.lowercased()) }
    }

    /// True when a reply can be sent: a request with an organizer to send it to.
    public var canReply: Bool { method == .request && organizer?.address.contains("@") == true }

    /// The iCalendar text of a reply from `address`. `now` is the reply's time stamp.
    public func reply(_ response: Response, from address: String, name: String = "", now: Date = Date()) -> String {
        var lines = ["BEGIN:VCALENDAR", "PRODID:-//Jevcast//Mail//EN", "VERSION:2.0", "CALSCALE:GREGORIAN", "METHOD:REPLY",
                     "BEGIN:VEVENT", "UID:" + Self.escape(uid), "SEQUENCE:\(sequence)", "DTSTAMP:" + Self.stamp(now)]
        lines += echoed
        let label = name.trimmingCharacters(in: .whitespaces)
        let cn = label.isEmpty ? "" : ";CN=\"" + Self.clean(label).replacingOccurrences(of: "\"", with: "'") + "\""
        lines.append("ATTENDEE;PARTSTAT=\(response.rawValue)\(cn):mailto:" + Self.clean(address))
        if !title.isEmpty { lines.append("SUMMARY:" + Self.escape(title)) }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(Self.fold).joined(separator: "\r\n") + "\r\n"
    }

    /// "Accepted: Design review", the subject mail clients use for a reply.
    public func replySubject(_ response: Response) -> String { response.verb + ": " + (title.isEmpty ? "Invitation" : title) }

    // MARK: Reading

    /// Joins continuation lines: a line that starts with a space or tab continues the one before.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: true).prefix(20_000) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty { lines[lines.count - 1].append(contentsOf: raw.dropFirst()) }
            else { lines.append(String(raw)) }
        }
        return lines
    }

    /// `NAME;PARAM=value;PARAM="quoted:value":value`. A colon or semicolon inside quotes is text.
    static func property(_ line: String) -> (name: String, params: [String: String], value: String)? {
        var head = "", quoted = false, split: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" { quoted.toggle() }
            if character == ":" && !quoted { split = index; break }
            head.append(character)
        }
        guard let split else { return nil }
        var pieces: [String] = [], current = ""
        quoted = false
        for character in head {
            if character == "\"" { quoted.toggle(); continue }
            if character == ";" && !quoted { pieces.append(current); current = ""; continue }
            current.append(character)
        }
        pieces.append(current)
        guard let name = pieces.first?.trimmingCharacters(in: .whitespaces).uppercased(), !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            params[piece[..<equals].uppercased()] = String(piece[piece.index(after: equals)...])
        }
        return (name, params, String(line[line.index(after: split)...]))
    }

    static func person(_ value: String, _ params: [String: String]) -> Person? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(trimmed.dropFirst(7))
        guard address.contains("@"), address.count <= 320, !address.contains(where: { $0.isWhitespace || $0 == "," || $0 == "<" || $0 == ">" }) else { return nil }
        return Person(name: params["CN"] ?? "", address: address, status: (params["PARTSTAT"] ?? "").uppercased())
    }

    /// `20261006`, `20261006T093000`, or `20261006T083000Z`, in the named zone when one is given.
    static func date(_ value: String, params: [String: String]) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let digits = text.filter(\.isNumber)
        guard digits.count == 8 || digits.count == 14, let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if text.hasSuffix("Z") { calendar.timeZone = TimeZone(identifier: "UTC")! }
        else if let zone = params["TZID"].flatMap(timeZone) { calendar.timeZone = zone }
        else { calendar.timeZone = .current }
        var parts = DateComponents(year: year, month: month, day: day)
        if digits.count == 14 {
            parts.hour = Int(digits.dropFirst(8).prefix(2)); parts.minute = Int(digits.dropFirst(10).prefix(2)); parts.second = Int(digits.dropFirst(12).prefix(2))
        }
        guard (1...12).contains(month), (1...31).contains(day), (parts.hour ?? 0) < 24, (parts.minute ?? 0) < 60 else { return nil }
        return calendar.date(from: parts)
    }

    /// A zone by its standard name, or by the Windows name Outlook writes.
    static func timeZone(_ name: String) -> TimeZone? {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let zone = TimeZone(identifier: trimmed) { return zone }
        return windowsZones[trimmed].flatMap(TimeZone.init(identifier:))
    }

    static let windowsZones: [String: String] = [
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik", "UTC": "UTC",
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw", "Romance Standard Time": "Europe/Paris",
        "E. Europe Standard Time": "Europe/Chisinau", "GTB Standard Time": "Europe/Bucharest", "FLE Standard Time": "Europe/Kiev",
        "Turkey Standard Time": "Europe/Istanbul", "Russian Standard Time": "Europe/Moscow", "Israel Standard Time": "Asia/Jerusalem",
        "Arabian Standard Time": "Asia/Dubai", "India Standard Time": "Asia/Kolkata", "China Standard Time": "Asia/Shanghai",
        "Singapore Standard Time": "Asia/Singapore", "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
        "AUS Eastern Standard Time": "Australia/Sydney", "New Zealand Standard Time": "Pacific/Auckland",
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax",
        "E. South America Standard Time": "America/Sao_Paulo", "South Africa Standard Time": "Africa/Johannesburg"
    ]

    /// `PT1H30M`, `P1D`, `P1W`. Negative lengths are refused.
    static func duration(_ value: String) -> TimeInterval? {
        var text = Substring(value.trimmingCharacters(in: .whitespaces).uppercased())
        guard text.first == "P" else { return nil }
        text = text.dropFirst()
        var total = 0.0, number = "", inTime = false
        for character in text {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch (character, inTime) {
            case ("W", false): total += amount * 604_800
            case ("D", false): total += amount * 86_400
            case ("H", true): total += amount * 3600
            case ("M", true): total += amount * 60
            case ("S", true): total += amount
            default: return nil
            }
        }
        return number.isEmpty && total > 0 && total <= 366 * 86_400 ? total : nil
    }

    static func unescape(_ value: String) -> String {
        var out = "", escaped = false
        for character in value {
            if escaped {
                out.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" { escaped = true } else { out.append(character) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Writing

    static func escape(_ value: String) -> String {
        clean(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,"))
    }

    /// No line breaks or other control characters: one value can never start a second property.
    static func clean(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
    }

    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }

    /// Lines of at most 75 bytes; a longer one continues on the next line after a space.
    static func fold(_ line: String) -> String {
        let cleaned = clean(line)
        guard cleaned.utf8.count > 75 else { return cleaned }
        var out = "", count = 0
        for character in cleaned {
            let size = String(character).utf8.count
            if count + size > 75 { out += "\r\n "; count = 1 }
            out.append(character); count += size
        }
        return out
    }
}
