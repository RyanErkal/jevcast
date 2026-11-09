import Foundation

/// A `mailto:` link as a new message's fields (RFC 6068). Only addresses, subject, and text are
/// read. Other fields, such as attachments, are ignored.
public struct MailtoLink: Equatable, Sendable {
    public var to: [String] = []
    public var cc: [String] = []
    public var bcc: [String] = []
    public var subject = ""
    public var body = ""

    public init?(_ url: URL) { self.init(url.absoluteString) }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 16_384, trimmed.lowercased().hasPrefix("mailto:") else { return nil }
        let rest = trimmed.dropFirst(7)
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        to = Self.addresses(String(parts.first ?? ""))
        if parts.count > 1 {
            for field in parts[1].split(separator: "&") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let value = String(pair[1]).removingPercentEncoding ?? String(pair[1])
                switch pair[0].lowercased() {
                case "to": to += Self.addresses(String(pair[1]))
                case "cc": cc += Self.addresses(String(pair[1]))
                case "bcc": bcc += Self.addresses(String(pair[1]))
                case "subject": subject = Self.oneLine(value)
                case "body": body = String(value.replacingOccurrences(of: "\r\n", with: "\n").prefix(100_000))
                default: continue
                }
            }
        }
        guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty || !subject.isEmpty || !body.isEmpty else { return nil }
    }

    static func addresses(_ encoded: String) -> [String] {
        encoded.split(separator: ",").compactMap { piece in
            let address = (String(piece).removingPercentEncoding ?? String(piece)).trimmingCharacters(in: .whitespaces)
            guard address.contains("@"), address.count <= 320,
                  !address.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" || $0 == "\"" }) else { return nil }
            return address
        }
    }

    static func oneLine(_ value: String) -> String {
        String(value.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) }.prefix(998))
    }
}

/// The ways a mailing list says it can be left, from its `List-Unsubscribe` header (RFC 2369).
/// Jevcast sends the list's own unsubscribe email, or opens its web page in the browser. It never
/// makes the web request itself.
public struct MailUnsubscribe: Equatable, Sendable {
    public let mail: MailtoLink?
    public let web: URL?

    public init?(header: String?) {
        guard let header, header.count <= 8192 else { return nil }
        var mail: MailtoLink?, web: URL?
        var current = "", inside = false
        for character in header {
            if character == "<" { inside = true; current = ""; continue }
            if character == ">" {
                if inside {
                    let value = current.filter { !$0.isWhitespace }
                    if mail == nil, let link = MailtoLink(value), link.to.count == 1 { mail = link }
                    else if web == nil, let url = URL(string: value), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
                            url.user == nil, url.password == nil { web = url }
                }
                inside = false; continue
            }
            if inside { current.append(character) }
        }
        guard mail != nil || web != nil else { return nil }
        self.mail = mail; self.web = web
    }
}
