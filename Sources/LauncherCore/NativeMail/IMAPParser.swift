import Foundation

public struct IMAPParseError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// Parses one complete server reply, as `IMAPFramer` returns it: the line and every literal in it.
/// It works on bytes, so 8-bit text and literals keep their exact bytes. Unknown replies become
/// `.other`, so a server extension never stops a session.
public struct IMAPParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    /// Nesting limit, so a hostile reply cannot exhaust the stack.
    static let maxDepth = 40

    public static func parse(_ bytes: [UInt8]) throws -> IMAPResponse {
        var parser = IMAPParser(bytes: bytes)
        return try parser.response()
    }

    init(bytes: [UInt8]) { self.bytes = bytes }

    // MARK: Replies

    mutating func response() throws -> IMAPResponse {
        guard let first = peek() else { throw fail("empty reply") }
        if first == Byte.plus {
            index += 1
            if peek() == Byte.space { index += 1 }
            return .continuation(restOfLine())
        }
        if first == Byte.star {
            index += 1
            try expect(Byte.space)
            return .untagged(try untagged())
        }
        let tag = word()
        guard !tag.isEmpty else { throw fail("missing tag") }
        try expect(Byte.space)
        let name = word().uppercased()
        guard let status = IMAPStatus(rawValue: name) else { throw fail("unknown status \(name)") }
        let (code, text) = codeAndText()
        return .tagged(tag: tag, IMAPStatusText(status: status, code: code, text: text))
    }

    mutating func untagged() throws -> IMAPUntagged {
        let first = word()
        if let number = UInt32(first) {
            try expect(Byte.space)
            let kind = word().uppercased()
            switch kind {
            case "EXISTS": return .exists(number)
            case "RECENT": return .recent(number)
            case "EXPUNGE": return .expunge(number)
            case "FETCH":
                try expect(Byte.space)
                return .fetch(sequence: number, try fetch())
            case "UIDFETCH":
                // UIDONLY (RFC 9586): the number is the UID, and there is no message number.
                try expect(Byte.space)
                var data = try fetch()
                if data.uid == nil { data.uid = number }
                return .fetch(sequence: 0, data)
            default: return .other(kind)
            }
        }
        let name = first.uppercased()
        switch name {
        case "OK", "NO", "BAD", "PREAUTH", "BYE":
            let (code, text) = codeAndText()
            return .status(IMAPStatusText(status: IMAPStatus(rawValue: name)!, code: code, text: text))
        case "CAPABILITY": return .capability(words())
        case "ENABLED": return .enabled(words())
        case "FLAGS":
            try expect(Byte.space)
            return .flags(try list().compactMap(\.text))
        case "LIST", "LSUB", "XLIST":
            try expect(Byte.space)
            return .list(try listEntry())
        case "SEARCH": return try search()
        case "ESEARCH": return .esearch(try esearch())
        case "VANISHED": return try vanished()
        case "STATUS":
            try expect(Byte.space)
            return try mailboxStatus()
        default: return .other(name)
        }
    }

    /// A status's optional `[CODE values]` and its text.
    mutating func codeAndText() -> (IMAPResponseCode?, String) {
        if peek() == Byte.space { index += 1 }
        var code: IMAPResponseCode?
        if peek() == Byte.openBracket {
            code = responseCode()
            if peek() == Byte.space { index += 1 }
        }
        return (code, restOfLine())
    }

    /// Reads to the matching `]`, outside quotes and lists. A code whose values do not parse keeps
    /// its text as one atom, so a server's own codes never fail a reply.
    mutating func responseCode() -> IMAPResponseCode? {
        let start = index + 1
        var cursor = start, parens = 0, quoted = false
        while cursor < bytes.count, bytes[cursor] != Byte.cr, bytes[cursor] != Byte.lf {
            let byte = bytes[cursor]
            if quoted {
                if byte == Byte.backslash { cursor += 1 } else if byte == Byte.quote { quoted = false }
            } else if byte == Byte.quote { quoted = true }
            else if byte == Byte.openParen { parens += 1 }
            else if byte == Byte.closeParen { parens -= 1 }
            else if byte == Byte.closeBracket && parens <= 0 { break }
            cursor += 1
        }
        let inner = Array(bytes[start..<min(cursor, bytes.count)])
        index = min(cursor + 1, bytes.count)
        var sub = IMAPParser(bytes: inner)
        let name = sub.word().uppercased()
        guard !name.isEmpty else { return nil }
        var values: [IMAPValue] = []
        let valuesStart = sub.index
        do {
            while let byte = sub.peek() {
                if byte == Byte.space { sub.index += 1; continue }
                values.append(try sub.value())
            }
        } catch {
            let rest = String(decoding: inner[min(valuesStart, inner.count)...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            values = rest.isEmpty ? [] : [.atom(rest)]
        }
        return IMAPResponseCode(name: name, values: values)
    }

    mutating func listEntry() throws -> IMAPListEntry {
        let flags = try list().compactMap(\.text)
        try expect(Byte.space)
        let delimiterValue = try value()
        try expect(Byte.space)
        let nameValue = try value()
        guard let name = nameValue.text else { throw fail("LIST without a name") }
        return IMAPListEntry(flags: flags, delimiter: delimiterValue.text, rawName: name)
    }

    mutating func search() throws -> IMAPUntagged {
        var numbers: [UInt32] = []
        var modSeq: UInt64?
        while let byte = peek(), byte != Byte.cr, byte != Byte.lf {
            if byte == Byte.space { index += 1; continue }
            let item = try value()
            if let values = item.list, values.first?.text?.uppercased() == "MODSEQ" { modSeq = values.dropFirst().first?.number }
            else if let number = item.number, let small = UInt32(exactly: number) { numbers.append(small) }
        }
        return .search(numbers, modSeq: modSeq)
    }

    mutating func esearch() throws -> IMAPESearch {
        var result = IMAPESearch()
        while let byte = peek(), byte != Byte.cr, byte != Byte.lf {
            if byte == Byte.space { index += 1; continue }
            let item = try value()
            guard case .atom(let atom) = item else { continue } // (TAG "A1")
            switch atom.uppercased() {
            case "UID": result.uid = true
            case "ALL": result.all = try nextValue().text.flatMap(IMAPSequenceSet.init(parsing:))
            case "MIN": result.min = try nextValue().number.flatMap(UInt32.init(exactly:))
            case "MAX": result.max = try nextValue().number.flatMap(UInt32.init(exactly:))
            case "COUNT": result.count = try nextValue().number.flatMap(UInt32.init(exactly:))
            default: _ = try nextValue()
            }
        }
        return result
    }

    mutating func vanished() throws -> IMAPUntagged {
        var earlier = false
        var set: IMAPSequenceSet?
        while let byte = peek(), byte != Byte.cr, byte != Byte.lf {
            if byte == Byte.space { index += 1; continue }
            let item = try value()
            if let values = item.list { earlier = values.contains { $0.text?.uppercased() == "EARLIER" } }
            else if let text = item.text { set = IMAPSequenceSet(parsing: text) }
        }
        guard let set else { throw fail("VANISHED without UIDs") }
        return .vanished(earlier: earlier, set)
    }

    mutating func mailboxStatus() throws -> IMAPUntagged {
        guard let name = try value().text else { throw fail("STATUS without a name") }
        try expect(Byte.space)
        let items = try list()
        var result: [String: UInt64] = [:]
        var cursor = 0
        while cursor + 1 < items.count {
            if let key = items[cursor].text?.uppercased(), let number = items[cursor + 1].number { result[key] = number }
            cursor += 2
        }
        return .mailboxStatus(name: ModifiedUTF7.decode(name), result)
    }

    // MARK: FETCH

    mutating func fetch() throws -> IMAPFetch {
        try expect(Byte.openParen)
        var result = IMAPFetch()
        while true {
            guard let byte = peek() else { throw fail("unterminated FETCH") }
            if byte == Byte.closeParen { index += 1; break }
            if byte == Byte.space { index += 1; continue }
            let key = atom()
            guard !key.isEmpty else { throw fail("FETCH item name expected") }
            try expect(Byte.space)
            Self.apply(key, try value(), to: &result)
        }
        return result
    }

    static func apply(_ key: String, _ value: IMAPValue, to fetch: inout IMAPFetch) {
        let upper = key.uppercased()
        switch upper {
        case "UID": fetch.uid = value.number.flatMap(UInt32.init(exactly:))
        case "FLAGS": fetch.flags = value.list?.compactMap(\.text) ?? []
        case "INTERNALDATE": fetch.internalDate = value.text.flatMap(IMAPDate.parse)
        case "RFC822.SIZE": fetch.size = value.number
        case "MODSEQ": fetch.modSeq = value.list?.first?.number ?? value.number
        case "X-GM-MSGID": fetch.gmailMessageID = value.number
        case "X-GM-THRID": fetch.gmailThreadID = value.number
        case "X-GM-LABELS": fetch.gmailLabels = value.list?.compactMap(\.text) ?? []
        case "RFC822", "RFC822.HEADER", "RFC822.TEXT":
            if case .string(let data) = value { fetch.sections[upper] = data }
        default:
            guard upper.hasPrefix("BODY[") || upper.hasPrefix("BINARY["), case .string(let data) = value,
                  let open = upper.firstIndex(of: "["), let close = upper.lastIndex(of: "]"), open < close else { return }
            fetch.sections[section(String(upper[upper.index(after: open)..<close]))] = data
        }
    }

    /// "HEADER.FIELDS  (FROM   SUBJECT)" → "HEADER.FIELDS (FROM SUBJECT)", so lookups need not match spacing.
    static func section(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Values

    mutating func value() throws -> IMAPValue {
        guard let byte = peek() else { throw fail("value expected") }
        switch byte {
        case Byte.openParen: return .list(try list())
        case Byte.quote: return .string(try quoted())
        case Byte.openBrace: return .string(try literal())
        case Byte.tilde where peek(1) == Byte.openBrace:
            index += 1
            return .string(try literal())
        default:
            let text = atom()
            guard !text.isEmpty else { throw fail("unexpected byte \(byte)") }
            return text.caseInsensitiveCompare("NIL") == .orderedSame ? .nilValue : .atom(text)
        }
    }

    private mutating func nextValue() throws -> IMAPValue {
        while peek() == Byte.space { index += 1 }
        return try value()
    }

    mutating func list() throws -> [IMAPValue] {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw fail("lists nested too deeply") }
        try expect(Byte.openParen)
        var values: [IMAPValue] = []
        while true {
            guard let byte = peek() else { throw fail("unterminated list") }
            if byte == Byte.closeParen { index += 1; return values }
            if byte == Byte.space { index += 1; continue }
            if byte == Byte.cr || byte == Byte.lf { throw fail("line ended inside a list") }
            values.append(try value())
        }
    }

    /// An atom, a number, or a flag such as `\Seen`. A `[...]` inside it, as in `BODY[HEADER]` or
    /// `[Gmail]`, belongs to it, and so does a partial range such as `<0>`.
    mutating func atom() -> String {
        let start = index
        while let byte = peek() {
            if byte == Byte.openBracket, let close = closingBracket(from: index) { index = close + 1; continue }
            if byte == Byte.space || byte == Byte.openParen || byte == Byte.closeParen || byte == Byte.closeBracket
                || byte == Byte.quote || byte == Byte.openBrace || byte == Byte.cr || byte == Byte.lf { break }
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private func closingBracket(from start: Int) -> Int? {
        var cursor = start + 1
        while cursor < bytes.count, bytes[cursor] != Byte.cr, bytes[cursor] != Byte.lf {
            if bytes[cursor] == Byte.closeBracket { return cursor }
            cursor += 1
        }
        return nil
    }

    mutating func quoted() throws -> Data {
        index += 1
        var out: [UInt8] = []
        while let byte = peek() {
            index += 1
            if byte == Byte.backslash, let next = peek() { out.append(next); index += 1; continue }
            if byte == Byte.quote { return Data(out) }
            if byte == Byte.cr || byte == Byte.lf { break }
            out.append(byte)
        }
        throw fail("unterminated quoted string")
    }

    mutating func literal() throws -> Data {
        index += 1
        let start = index
        while let byte = peek(), byte >= Byte.zero, byte <= Byte.nine { index += 1 }
        guard let count = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw fail("literal without a size") }
        if peek() == Byte.plus { index += 1 }
        try expect(Byte.closeBrace)
        if peek() == Byte.cr { index += 1 }
        try expect(Byte.lf)
        guard count <= bytes.count - index else { throw fail("literal is cut short") }
        defer { index += count }
        return Data(bytes[index..<index + count])
    }

    // MARK: Text

    /// Up to the next space or line end.
    mutating func word() -> String {
        let start = index
        while let byte = peek(), byte != Byte.space, byte != Byte.cr, byte != Byte.lf { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// The rest of the line, split on spaces.
    mutating func words() -> [String] {
        restOfLine().split(separator: " ").map(String.init)
    }

    mutating func restOfLine() -> String {
        let start = index
        while let byte = peek(), byte != Byte.cr, byte != Byte.lf { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// The next space-separated value, or nil at the end of the line. For reading command lines.
    mutating func nextArgument() throws -> IMAPValue? {
        while peek() == Byte.space { index += 1 }
        guard let byte = peek(), byte != Byte.cr, byte != Byte.lf else { return nil }
        return try value()
    }

    private func peek(_ offset: Int = 0) -> UInt8? {
        index + offset < bytes.count ? bytes[index + offset] : nil
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard peek() == byte else { throw fail("expected \(Character(Unicode.Scalar(byte)))") }
        index += 1
    }

    private func fail(_ text: String) -> IMAPParseError {
        IMAPParseError(description: "Could not read the server's reply: \(text).")
    }
}

/// ASCII bytes the IMAP and SMTP readers compare against.
enum Byte {
    static let space: UInt8 = 0x20, cr: UInt8 = 0x0D, lf: UInt8 = 0x0A, quote: UInt8 = 0x22, backslash: UInt8 = 0x5C
    static let openParen: UInt8 = 0x28, closeParen: UInt8 = 0x29, openBracket: UInt8 = 0x5B, closeBracket: UInt8 = 0x5D
    static let openBrace: UInt8 = 0x7B, closeBrace: UInt8 = 0x7D, plus: UInt8 = 0x2B, star: UInt8 = 0x2A, tilde: UInt8 = 0x7E
    static let zero: UInt8 = 0x30, nine: UInt8 = 0x39, dot: UInt8 = 0x2E
}

/// IMAP's date-time, "17-Jul-1996 02:44:25 -0700", read and written without a formatter.
public enum IMAPDate {
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let day = parts[0].split(separator: "-"), time = parts[1].split(separator: ":"), zone = parts[2]
        guard day.count == 3, let d = Int(day[0]), let monthIndex = months.firstIndex(of: day[1].lowercased()), let y = Int(day[2]),
              time.count == 3, let h = Int(time[0]), let m = Int(time[1]), let s = Int(time[2]),
              zone.count == 5, let sign = zone.first, sign == "+" || sign == "-",
              let zh = Int(zone.dropFirst().prefix(2)), let zm = Int(zone.suffix(2)) else { return nil }
        let offset = (zh * 3600 + zm * 60) * (sign == "-" ? -1 : 1)
        let seconds = days(year: y, month: monthIndex + 1, day: d) * 86_400 + h * 3600 + m * 60 + s - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// For APPEND. Always written in UTC.
    public static func format(_ date: Date) -> String {
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        let dayCount = Int((Double(total) / 86_400).rounded(.down))
        let (y, mo, d) = civil(fromDays: dayCount)
        let rest = total - dayCount * 86_400
        let pad = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return "\(pad(d))-\(months[mo - 1].capitalized)-\(y) \(pad(rest / 3600)):\(pad(rest % 3600 / 60)):\(pad(rest % 60)) +0000"
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
