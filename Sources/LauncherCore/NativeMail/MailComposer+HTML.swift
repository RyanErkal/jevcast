import Foundation

extension MailComposer {
    static func bodyPart(_ message: OutgoingMessage) -> Data {
        let (headers, text) = textPart(message.body)
        let plain = Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + text).utf8)
        var body = plain
        let inline = message.attachments.filter { $0.contentID != nil }
        if let html = message.html {
            let htmlPart = Data(("Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
                + quotedPrintable(crlf(MailHTML.clean(html))) + "\r\n").utf8)
            let rich = inline.isEmpty ? htmlPart : multipart("related", [htmlPart] + inline.map(attachmentPart))
            body = multipart("alternative", [plain, rich])
        }
        else if !inline.isEmpty { body = multipart("mixed", [plain] + inline.map(attachmentPart)) }
        let files = message.attachments.filter { $0.contentID == nil }
        if !files.isEmpty { body = multipart("mixed", [body] + files.map(attachmentPart)) }
        return body
    }

    private static func multipart(_ kind: String, _ parts: [Data]) -> Data {
        let boundary = "jevcast-" + UUID().uuidString.lowercased()
        let type = kind == "related" ? "; type=\"text/html\"" : ""
        var result = Data("Content-Type: multipart/\(kind); boundary=\"\(boundary)\"\(type)\r\n\r\n".utf8)
        for part in parts {
            result.append(Data("--\(boundary)\r\n".utf8)); result.append(part)
            result.append(Data("\r\n".utf8))
        }
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }
}

/// Passive email HTML only. This code never renders or fetches a resource.
public enum MailHTML {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func plain(_ text: String) -> String {
        "<div style=\"white-space:pre-wrap\">" + escape(text) + "</div>"
    }

    public static func clean(_ html: String) -> String {
        var result = html
        for pattern in [
            "(?is)<(script|iframe|object|embed|form|svg|math|template)\\b[^>]*>.*?</\\1\\s*>",
            "(?is)</?(script|iframe|object|embed|form|base|meta|svg|math|template|input|button|textarea|select)\\b[^>]*>",
            "(?is)\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            "(?is)\\s+(href|src|action)\\s*=\\s*([\"'])\\s*(javascript|vbscript|file):.*?\\2"
        ] { result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        guard let urls = try? NSRegularExpression(pattern: #"(?is)\s+(href|src|background|action|poster|data|xlink:href)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#) else { return result }
        for match in urls.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result), let valueRange = Range(match.range(at: 2), in: result) else { continue }
            let raw = String(result[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let decoded = HTMLText.decodeNumericEntities(raw).replacingOccurrences(of: "&colon;", with: ":").replacingOccurrences(of: "&Tab;", with: "").replacingOccurrences(of: "&NewLine;", with: "")
            let compact = String(decoded.unicodeScalars.filter { $0.value > 32 && $0.value != 127 }).lowercased()
            if let colon = compact.firstIndex(of: ":") {
                let scheme = String(compact[..<colon])
                let safeData = compact.hasPrefix("data:image/") && !compact.hasPrefix("data:image/svg")
                if !["http", "https", "mailto", "tel", "cid"].contains(scheme) && !safeData { result.removeSubrange(range) }
            }
        }
        return result
    }

    /// The quote of a reply: Apple Mail's `type="cite"` block with a blue bar, the attribution
    /// line first, then the original's own HTML, cleaned, with its styles kept inside the quote.
    public static func quoted(_ original: MIMEMessage, attribution: String) -> String {
        let (style, className, fragment) = quoteParts(original)
        return "<div><br></div>" + style + "<blockquote type=\"cite\" class=\"" + className + "\" style=\"" + quoteStyle + "\">"
            + "<div style=\"color:" + quoteColor + "\">" + escape(attribution) + "</div><br>" + fragment + "</blockquote>"
    }

    /// A forward: "Begin forwarded message:", the original's From, Subject, Date, To, and Cc, then
    /// its HTML, as Apple Mail shows it.
    public static func forwarded(_ original: MIMEMessage, date: String) -> String {
        let (style, className, fragment) = quoteParts(original)
        var rows: [(String, String)] = []
        if let from = original.header("From") { rows.append(("From", from)) }
        if let subject = original.header("Subject") { rows.append(("Subject", subject)) }
        rows.append(("Date", date))
        if let to = original.header("To") { rows.append(("To", to)) }
        if let cc = original.header("Cc") { rows.append(("Cc", cc)) }
        let header = rows.map { "<div><b>" + $0.0 + ":</b> " + escape($0.1) + "</div>" }.joined()
        return "<div><br></div><div>Begin forwarded message:</div><br>" + style + "<blockquote type=\"cite\" class=\"" + className
            + "\" style=\"" + quoteStyle + "\">" + header + "<br>" + fragment + "</blockquote>"
    }

    static let quoteColor = "#5856d6"
    static let quoteStyle = "margin:0;padding:0 0 0 12px;border-left:2px solid #5856d6"

    /// The original's cleaned HTML without its document wrapper, and its styles scoped to the quote.
    private static func quoteParts(_ original: MIMEMessage) -> (style: String, className: String, fragment: String) {
        let body = original.html.map(clean) ?? plain(original.readableText)
        let className = "jevcast-quote-" + UUID().uuidString.lowercased()
        let (css, fragment) = scopedParts(body, className: className)
        return (css, className, fragment)
    }

    /// A complete sender document embedded in a thread without leaking styles into other replies.
    public static func threadFragment(_ html: String, className: String) -> String {
        let (css, fragment) = scopedParts(clean(html), className: className)
        return css + "<div class=\"" + escape(className) + "\">" + fragment + "</div>"
    }

    private static func scopedParts(_ body: String, className: String) -> (String, String) {
        var css = ""
        if let regex = try? NSRegularExpression(pattern: #"(?is)<style\b[^>]*>(.*?)</style\s*>"#) {
            for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let range = Range(match.range(at: 1), in: body) { css += MailQuoteCSS.scope(String(body[range]), className: className) }
            }
        }
        // Remove document wrappers so a quoted HTML document does not replace the reply's head.
        let fragment = body
            .replacingOccurrences(of: #"(?is)<body\b([^>]*)>"#, with: "<div$1>", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)</body\s*>"#, with: "</div>", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<!doctype[^>]*>|</?html\\b[^>]*>|<head\\b[^>]*>.*?</head>|<style\\b[^>]*>.*?</style\\s*>", with: "", options: .regularExpression)
        return (css.isEmpty ? "" : "<style>" + css + "</style>", fragment)
    }
}
