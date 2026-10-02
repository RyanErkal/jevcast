import Foundation

/// Keep email selectors inside their quote, including rules from the original document's head.
enum MailQuoteCSS {
    static func scope(_ css: String, className: String) -> String {
        let css = css.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: "", options: .regularExpression)
        var result = "", cursor = css.startIndex
        while cursor < css.endIndex, let open = css[cursor...].firstIndex(of: "{") {
            var end = css.index(after: open), depth = 1, quote: Character?, escaped = false
            while end < css.endIndex && depth > 0 {
                let character = css[end]
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if let current = quote { if character == current { quote = nil } }
                else if character == "\"" || character == "'" { quote = character }
                else if character == "{" { depth += 1 }
                else if character == "}" { depth -= 1 }
                end = css.index(after: end)
            }
            guard depth == 0 else { break }
            let header = String(css[cursor..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            let contents = String(css[css.index(after: open)..<css.index(before: end)])
            if header.lowercased().hasPrefix("@media") || header.lowercased().hasPrefix("@supports") {
                result += header + "{" + scope(contents, className: className) + "}"
            } else if !header.hasPrefix("@"), !header.contains(";") {
                let selectors = splitSelectors(header).compactMap { selector -> String? in
                    let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !selector.isEmpty else { return nil }
                    let root = #"(?i)^(html\s+body|html|body|:root)\b"#
                    if selector.range(of: root, options: .regularExpression) != nil {
                        // A sibling of the quote is outside it. Unsupported root selectors are omitted.
                        guard !selector.contains("+"), !selector.contains("~"), !selector.contains("\\") else { return nil }
                        return selector.replacingOccurrences(of: root, with: "." + className, options: .regularExpression)
                    }
                    return "." + className + " " + selector
                }
                if !selectors.isEmpty && !contents.contains("{") && !contents.lowercased().contains("expression(") && !contents.lowercased().contains("javascript:") && !contents.lowercased().contains("behavior:") {
                    result += selectors.joined(separator: ",") + "{" + contents + "}"
                }
            }
            cursor = end
        }
        return result
    }

    private static func splitSelectors(_ value: String) -> [String] {
        var result: [String] = [], start = value.startIndex, depth = 0, quote: Character?, escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if let current = quote { if character == current { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "(" || character == "[" { depth += 1 }
            else if character == ")" || character == "]" { depth = max(0, depth - 1) }
            else if character == "," && depth == 0 {
                result.append(String(value[start..<index])); start = value.index(after: index)
            }
        }
        result.append(String(value[start...]))
        return result
    }
}
