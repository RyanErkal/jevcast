import Foundation

/// Local clean-up of a dictation transcript. Runs on this Mac before, or instead of, Luna.
public enum DictationText {
    private static let fillers = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}'])(?:u+m+|u+h+|e+r+m+)(?![\p{L}\p{N}'])[,.]?"#)
    private static let spaces = try! NSRegularExpression(pattern: #"[ \t]+"#)
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #" +([,.!?;:])"#)

    /// Removes "um", "uh", and "erm", collapses spaces, trims, and capitalises the first letter.
    public static func clean(_ text: String) -> String {
        var result = replace(fillers, in: text, with: "")
        result = replace(spaces, in: result, with: " ")
        result = replace(spaceBeforePunctuation, in: result, with: "$1")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A filler at the start can leave a comma behind: "Um, so" must not become ", so".
        while let first = result.first, ",;".contains(first) { result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard let first = result.first else { return "" }
        return first.uppercased() + result.dropFirst()
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
