import Foundation

/// Plain-text mail with its web and mail addresses turned into links that open when clicked.
enum MailText {
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text), let attributed = Range(range, in: result) else { continue }
            result[attributed].link = url
        }
        return result
    }
}
