import Foundation

/// Removes text that looks like a key or token before script output goes to a diagnosis agent.
public enum Redactor {
    static let patterns: [NSRegularExpression] = [
        #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#,
        #"(?i)\b([A-Z0-9_]*(api[_-]?key|token|secret|passw(or)?d|auth)[A-Z0-9_]*)\s*[=:]\s*("[^"]*"|'[^']*'|\S+)"#,
        #"\b(sk|pk|rk)-[A-Za-z0-9_-]{12,}"#,
        #"\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{16,}"#,
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"#,
        #"\b[A-Za-z0-9+/_-]{40,}={0,2}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Replaces likely secrets, and every exact value in `known`, with "[redacted]".
    public static func redact(_ text: String, known: [String] = []) -> String {
        var out = text
        for value in known where value.count >= 4 { out = out.replacingOccurrences(of: value, with: "[redacted]") }
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        return out
    }

    /// The last `maxBytes` of `data` as text, cut at a character boundary.
    public static func tail(_ data: Data, maxBytes: Int) -> String {
        var slice = data.suffix(maxBytes)
        // Drop UTF-8 continuation bytes at the start.
        while let first = slice.first, first & 0xC0 == 0x80 { slice = slice.dropFirst() }
        return String(decoding: slice, as: UTF8.self)
    }
}
