import Foundation

/// A parsed email: headers, the best text and HTML bodies, and attachment names.
/// Built for reading Apple Mail's `.emlx` files. It never runs or loads anything.
public struct MIMEMessage: Equatable, Sendable {
    public struct Attachment: Equatable, Sendable {
        public let name: String
        public let mimeType: String
        public let size: Int
    }
    public let headers: [(name: String, value: String)]
    public var plainText: String?
    public var html: String?
    public var attachments: [Attachment] = []

    public static func == (lhs: MIMEMessage, rhs: MIMEMessage) -> Bool {
        lhs.headers.map { $0.name + ":" + $0.value } == rhs.headers.map { $0.name + ":" + $0.value }
            && lhs.plainText == rhs.plainText && lhs.html == rhs.html && lhs.attachments == rhs.attachments
    }

    /// The first header with this name, decoded. Names are not case-sensitive.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Text for reading and for Luna: the plain part, or the HTML part as text.
    public var readableText: String {
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plainText }
        return html.map(HTMLText.plain) ?? ""
    }

    /// Reads an `.emlx` file: a byte count line, the message, then Apple's property list.
    public static func parseEMLX(_ data: Data) -> MIMEMessage? {
        guard let newline = data.firstIndex(of: 0x0A),
              let count = Int(String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)) else {
            return parse(data)
        }
        let start = data.index(after: newline)
        let end = min(data.endIndex, start + count)
        return parse(data[start..<end])
    }

    public static func parse(_ data: Data) -> MIMEMessage? {
        let (headerData, body) = splitHeaders(Data(data))
        let headers = parseHeaders(headerData)
        guard !headers.isEmpty else { return nil }
        var message = MIMEMessage(headers: headers)
        walk(headers: headers, body: body, into: &message, depth: 0)
        return message
    }

    // MARK: Parts

    private static func walk(headers: [(name: String, value: String)], body: Data, into message: inout MIMEMessage, depth: Int) {
        guard depth < 12 else { return }
        let contentType = value(headers, "Content-Type") ?? "text/plain"
        let (type, params) = parameters(contentType)
        let disposition = value(headers, "Content-Disposition").map(parameters)
        let filename = disposition?.1["filename"] ?? params["name"]
        let encoding = (value(headers, "Content-Transfer-Encoding") ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces)

        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for part in split(body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeaders(part)
                walk(headers: parseHeaders(partHeaders), body: partBody, into: &message, depth: depth + 1)
            }
            return
        }
        if type == "message/rfc822", let inner = parse(decode(body, encoding)) {
            // A forwarded message: its text follows, and its attachments count as this message's.
            if message.plainText == nil, let text = inner.plainText { message.plainText = text }
            if message.html == nil, let html = inner.html { message.html = html }
            message.attachments += inner.attachments
            return
        }
        let decoded = decode(body, encoding)
        let isAttachment = disposition?.0 == "attachment" || (filename != nil && !type.hasPrefix("text/"))
        if isAttachment || !(type == "text/plain" || type == "text/html") {
            if let filename { message.attachments.append(Attachment(name: EncodedWords.decode(filename), mimeType: type, size: decoded.count)) }
            return
        }
        let text = decodeText(decoded, charset: params["charset"])
        if type == "text/html" { if message.html == nil { message.html = text } }
        else if message.plainText == nil { message.plainText = text }
    }

    /// Splits at the first blank line.
    static func splitHeaders(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { return (Data(bytes[0..<index]), Data(bytes[(index + 2)...])) }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { return (Data(bytes[0..<index]), Data(bytes[(index + 3)...])) }
            }
            index += 1
        }
        return (data, Data())
    }

    /// Unfolds continuation lines and decodes encoded words.
    static func parseHeaders(_ data: Data) -> [(name: String, value: String)] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var result: [(String, String)] = []
        for line in text.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { continue }
                result.append((name, String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return result.map { ($0.0, EncodedWords.decode($0.1)) }
    }

    private static func value(_ headers: [(name: String, value: String)], _ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// "text/html; charset=utf-8" → ("text/html", ["charset": "utf-8"]).
    static func parameters(_ header: String) -> (String, [String: String]) {
        var parts: [String] = []
        var current = "", quoted = false
        for character in header {
            if character == "\"" { quoted.toggle(); continue }
            if character == ";" && !quoted { parts.append(current); current = ""; continue }
            current.append(character)
        }
        parts.append(current)
        let type = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            var key = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // RFC 2231: filename*=utf-8''name%20here
            if key.hasSuffix("*") {
                key.removeLast()
                if let quote = value.range(of: "''") { value = String(value[quote.upperBound...]).removingPercentEncoding ?? value }
            }
            params[key] = value
        }
        return (type, params)
    }

    static func split(_ body: Data, boundary: String) -> [Data] {
        let text = String(decoding: body, as: UTF8.self)
        let marker = "--" + boundary
        var parts: [Data] = []
        let pieces = text.components(separatedBy: marker)
        for piece in pieces.dropFirst() {
            if piece.hasPrefix("--") { break }
            var part = piece
            if part.hasPrefix("\r\n") { part.removeFirst(2) } else if part.hasPrefix("\n") { part.removeFirst() }
            parts.append(Data(part.utf8))
        }
        return parts
    }

    static func decode(_ body: Data, _ encoding: String) -> Data {
        switch encoding {
        case "base64":
            let cleaned = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable": return QuotedPrintable.decode(body)
        default: return body
        }
    }

    static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = Charset.encoding(charset), let text = String(data: data, encoding: encoding) { return text }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

public enum Charset {
    public static func encoding(_ name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name.trimmingCharacters(in: .whitespaces) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

public enum QuotedPrintable {
    public static func decode(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x37
            case 0x61...0x66: return byte - 0x57
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D { // "="
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    out.append(high << 4 | low); index += 3; continue
                }
            }
            out.append(byte); index += 1
        }
        return Data(out)
    }
}

/// RFC 2047 encoded words in headers: `=?utf-8?B?…?=` and `=?iso-8859-1?Q?…?=`.
public enum EncodedWords {
    public static func decode(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        var previousWasWord = false
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let charsetRange = Range(match.range(at: 1), in: text),
                  let kindRange = Range(match.range(at: 2), in: text), let payloadRange = Range(match.range(at: 3), in: text) else { continue }
            let between = String(text[last..<whole.lowerBound])
            // Whitespace between two encoded words is not part of the text.
            if !(previousWasWord && between.allSatisfy(\.isWhitespace)) { result += between }
            let charset = String(text[charsetRange]).split(separator: "*").first.map(String.init) ?? "utf-8"
            let payload = String(text[payloadRange])
            let data: Data?
            if text[kindRange].lowercased() == "b" { data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
            else { data = QuotedPrintable.decode(Data(payload.replacingOccurrences(of: "_", with: " ").utf8)) }
            if let data, let decoded = String(data: data, encoding: Charset.encoding(charset) ?? .utf8) { result += decoded }
            else { result += String(text[whole]) }
            last = whole.upperBound
            previousWasWord = true
        }
        result += text[last...]
        return result
    }
}

/// HTML to readable plain text, for Luna and for a message with no plain part.
public enum HTMLText {
    public static func plain(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            (#"(?is)<(script|style|head)[^>]*>.*?</\1>"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(p|div|tr|li|h[1-6]|table|blockquote)>"#, "\n"),
            (#"(?i)<li[^>]*>"#, "• "),
            (#"(?s)<[^>]+>"#, "")
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: #"&#(\d+);"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Parses "Name <a@b.c>, other@x.y" into display names and addresses.
public enum MailAddress {
    public static func list(_ header: String) -> [(name: String, address: String)] {
        var result: [(String, String)] = []
        var current = "", depth = 0, quoted = false
        func flush() {
            let part = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !part.isEmpty else { return }
            if let open = part.lastIndex(of: "<"), let close = part.lastIndex(of: ">"), open < close {
                let address = String(part[part.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                let name = String(part[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                result.append((name, address))
            } else {
                result.append(("", part))
            }
        }
        for character in header {
            if character == "\"" { quoted.toggle() }
            if !quoted && character == "<" { depth += 1 }
            if !quoted && character == ">" { depth -= 1 }
            if character == "," && !quoted && depth == 0 { flush(); continue }
            current.append(character)
        }
        flush()
        return result
    }
}
