import Foundation

/// A name and an address, such as "Sam" and "sam@example.com".
public struct MailContact: Equatable, Sendable, Hashable {
    public var name: String
    public var address: String
    public init(name: String = "", address: String) { self.name = name; self.address = address }
}

/// A message to send, in plain text, with optional attachments.
public struct OutgoingMessage: Sendable {
    public struct Attachment: Sendable, Equatable {
        public var filename: String
        public var mimeType: String
        public var data: Data
        public init(filename: String, mimeType: String, data: Data) { self.filename = filename; self.mimeType = mimeType; self.data = data }
    }
    public var from: MailContact
    public var to: [MailContact]
    public var cc: [MailContact] = []
    /// Receives the message but is never written in its headers.
    public var bcc: [MailContact] = []
    public var subject: String
    public var body: String
    /// The Message-ID being answered, with its angle brackets.
    public var inReplyTo: String?
    public var references: [String] = []
    public var attachments: [Attachment] = []
    public var date = Date()
    public var messageID: String

    public init(from: MailContact, to: [MailContact], subject: String, body: String) {
        self.from = from; self.to = to; self.subject = subject; self.body = body
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "jevcast.invalid"
        messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    /// Every address the server delivers to.
    public var recipients: [String] { (to + cc + bcc).map(\.address) }
}

/// Writes RFC 5322 messages: 7-bit headers with encoded words, and text as quoted-printable when
/// it is not plain ASCII. Values never carry a line break into a header.
public enum MailComposer {
    public static func render(_ message: OutgoingMessage) -> Data {
        var headers: [(String, String)] = [
            ("Date", rfc5322Date(message.date)),
            ("From", addressList([message.from])),
        ]
        if !message.to.isEmpty { headers.append(("To", addressList(message.to))) }
        if !message.cc.isEmpty { headers.append(("Cc", addressList(message.cc))) }
        headers.append(("Subject", encodedText(message.subject)))
        headers.append(("Message-ID", clean(message.messageID)))
        if let inReplyTo = message.inReplyTo, !inReplyTo.isEmpty { headers.append(("In-Reply-To", clean(inReplyTo))) }
        if !message.references.isEmpty { headers.append(("References", message.references.map(clean).joined(separator: " "))) }
        headers.append(("MIME-Version", "1.0"))

        var out = ""
        for (name, value) in headers { out += fold("\(name): \(value)") + "\r\n" }
        let (textHeaders, textBody) = textPart(message.body)
        if message.attachments.isEmpty {
            out += textHeaders.map { $0 + "\r\n" }.joined() + "\r\n" + textBody
            return Data(out.utf8)
        }
        let boundary = "jevcast-" + UUID().uuidString.lowercased()
        out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        out += "--\(boundary)\r\n" + textHeaders.map { $0 + "\r\n" }.joined() + "\r\n" + textBody + "\r\n"
        var data = Data(out.utf8)
        for attachment in message.attachments {
            data.append(contentsOf: "--\(boundary)\r\n".utf8)
            data.append(attachmentPart(attachment))
            data.append(contentsOf: "\r\n".utf8)
        }
        data.append(contentsOf: "--\(boundary)--\r\n".utf8)
        return data
    }

    // MARK: Parts

    /// The text part's headers and body. ASCII with short lines goes as 7bit; anything else as
    /// quoted-printable UTF-8.
    static func textPart(_ text: String) -> ([String], String) {
        let normalized = crlf(text)
        let lines = normalized.components(separatedBy: "\r\n")
        let body = normalized.hasSuffix("\r\n") ? normalized : normalized + "\r\n"
        if normalized.unicodeScalars.allSatisfy({ $0.isASCII && ($0.value >= 0x20 || $0 == "\r" || $0 == "\n" || $0 == "\t") }),
           lines.allSatisfy({ $0.utf8.count <= 900 }) {
            return (["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 7bit"], body)
        }
        return (["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"], quotedPrintable(body))
    }

    static func attachmentPart(_ attachment: OutgoingMessage.Attachment) -> Data {
        let type = clean(attachment.mimeType).lowercased()
        let name = parameter("filename", attachment.filename)
        // A message/rfc822 part must not be base64; one with 8-bit bytes or long lines goes as a file.
        if type == "message/rfc822", isSevenBit(attachment.data) {
            var part = Data("Content-Type: message/rfc822\r\nContent-Disposition: attachment; \(name)\r\n\r\n".utf8)
            part.append(attachment.data)
            if attachment.data.last != Byte.lf { part.append(contentsOf: [Byte.cr, Byte.lf]) }
            return part
        }
        let shownType = type == "message/rfc822" ? "application/octet-stream" : (type.contains("/") ? type : "application/octet-stream")
        var part = "Content-Type: \(shownType); \(parameter("name", attachment.filename))\r\n"
        part += "Content-Disposition: attachment; \(name)\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        part += attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
        return Data(part.utf8)
    }

    static func isSevenBit(_ data: Data) -> Bool {
        var lineLength = 0
        for byte in data {
            if byte >= 0x80 || byte == 0 { return false }
            lineLength = byte == Byte.lf ? 0 : lineLength + 1
            if lineLength > 990 { return false }
        }
        return true
    }

    /// `name="file.pdf"`, or RFC 2231 `name*=utf-8''…` for a name that is not plain ASCII.
    static func parameter(_ key: String, _ value: String) -> String {
        let cleaned = clean(value)
        if cleaned.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" }) {
            return "\(key)=\"\(cleaned)\""
        }
        let allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(0x80))).union(CharacterSet(charactersIn: "!#$&+-.^_`|~"))
        return "\(key)*=utf-8''" + (cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment")
    }

    // MARK: Headers

    /// "Name <a@b.c>, d@e.f", with names quoted or encoded as needed.
    static func addressList(_ contacts: [MailContact]) -> String {
        contacts.map { contact in
            let address = clean(contact.address)
            let name = clean(contact.name).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return address }
            return displayName(name) + " <" + address + ">"
        }.joined(separator: ", ")
    }

    static func displayName(_ name: String) -> String {
        if !name.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) { return encodedText(name) }
        let plain = name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == " " || "!#$%&'*+-/=?^_`{|}~".unicodeScalars.contains($0) }
        return plain ? name : "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Plain ASCII as is; other text as RFC 2047 encoded words of at most 68 characters each, so
    /// a header name and its first word still fit in 78.
    static func encodedText(_ text: String) -> String {
        let cleaned = clean(text)
        if cleaned.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) && !cleaned.contains("=?") { return cleaned }
        var words: [String] = []
        var chunk = ""
        for character in cleaned {
            if (chunk + String(character)).utf8.count > 40 {
                words.append(chunk); chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }.joined(separator: " ")
    }

    /// Folds a header line at spaces so lines stay near 78 characters.
    static func fold(_ line: String) -> String {
        guard line.count > 78 else { return line }
        var lines: [String] = []
        var current = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + 1 + word.count > 78 {
                lines.append(current); current = String(word)
            } else {
                current += current.isEmpty && lines.isEmpty ? String(word) : " " + word
            }
        }
        lines.append(current)
        return lines.joined(separator: "\r\n ")
    }

    /// No line breaks or other control characters in a header value.
    static func clean(_ value: String) -> String {
        String(value.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) })
    }

    static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    // MARK: Encodings

    /// Quoted-printable for UTF-8 text with CRLF line ends, soft breaks keeping lines under 76.
    static func quotedPrintable(_ text: String) -> String {
        var out = ""
        let hex = Array("0123456789ABCDEF")
        for line in text.components(separatedBy: "\r\n").enumerated() {
            if line.offset > 0 { out += "\r\n" }
            let bytes = Array(line.element.utf8)
            var current = ""
            for (index, byte) in bytes.enumerated() {
                let last = index == bytes.count - 1
                let piece: String
                if (byte >= 33 && byte <= 126 && byte != 61) || ((byte == 32 || byte == 9) && !last) {
                    piece = String(UnicodeScalar(byte))
                } else {
                    piece = "=" + String(hex[Int(byte >> 4)]) + String(hex[Int(byte & 0x0F)])
                }
                if current.count + piece.count > 75 {
                    out += current + "=\r\n"
                    current = ""
                }
                current += piece
            }
            out += current
        }
        return out
    }

    /// "Tue, 29 Sep 2026 06:38:36 +0300", in the Mac's time zone.
    public static func rfc5322Date(_ date: Date, timeZone: TimeZone = .current) -> String {
        let offset = timeZone.secondsFromGMT(for: date)
        let local = Int(date.timeIntervalSince1970.rounded(.down)) + offset
        let dayCount = Int((Double(local) / 86_400).rounded(.down))
        let (y, m, d) = IMAPDate.civil(fromDays: dayCount)
        let rest = local - dayCount * 86_400
        let weekday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][((dayCount % 7) + 7) % 7]
        let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m - 1]
        let pad = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        let sign = offset < 0 ? "-" : "+"
        let zone = pad(abs(offset) / 3600) + pad(abs(offset) % 3600 / 60)
        return "\(weekday), \(d) \(month) \(y) \(pad(rest / 3600)):\(pad(rest % 3600 / 60)):\(pad(rest % 60)) \(sign)\(zone)"
    }
}
