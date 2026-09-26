import Foundation

public struct ClipTransformError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Text changes done in code, never by a model. Each returns new text; the original entry is not changed.
public enum ClipTransform: String, CaseIterable, Sendable {
    case uppercase, lowercase, titleCase, trim, removeLineBreaks, sortLines, removeDuplicateLines
    case jsonPretty, jsonMinify, urlEncode, urlDecode, base64Encode, base64Decode, count

    public var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .trim: return "Trim Whitespace"
        case .removeLineBreaks: return "Remove Line Breaks"
        case .sortLines: return "Sort Lines"
        case .removeDuplicateLines: return "Remove Duplicate Lines"
        case .jsonPretty: return "JSON Pretty Print"
        case .jsonMinify: return "JSON Minify"
        case .urlEncode: return "URL Encode"
        case .urlDecode: return "URL Decode"
        case .base64Encode: return "Base64 Encode"
        case .base64Decode: return "Base64 Decode"
        case .count: return "Count Characters, Words, and Lines"
        }
    }

    /// Count only reports; every other transform makes a new entry.
    public var makesEntry: Bool { self != .count }

    public func apply(_ text: String) throws -> String {
        guard !text.isEmpty else { throw ClipTransformError("There is no text to change.") }
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeLineBreaks:
            return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        case .sortLines:
            return Self.lines(text).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .removeDuplicateLines:
            var seen = Set<String>()
            return Self.lines(text).filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .jsonPretty, .jsonMinify:
            guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                throw ClipTransformError("This is not valid JSON.")
            }
            var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
            if self == .jsonPretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
            guard let out = try? JSONSerialization.data(withJSONObject: object, options: options),
                  let string = String(data: out, encoding: .utf8) else { throw ClipTransformError("This is not valid JSON.") }
            return string
        case .urlEncode:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ClipTransformError("The text could not be encoded.") }
            return encoded
        case .urlDecode:
            guard let decoded = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                throw ClipTransformError("This is not valid URL encoding.")
            }
            return decoded
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            value = value.filter { !$0.isWhitespace }
            if value.count % 4 != 0 { value += String(repeating: "=", count: 4 - value.count % 4) }
            guard let data = Data(base64Encoded: value) else { throw ClipTransformError("This is not valid Base64.") }
            guard let decoded = String(data: data, encoding: .utf8) else { throw ClipTransformError("The decoded data is not text.") }
            return decoded
        case .count:
            return Self.countSummary(text)
        }
    }

    public static func countSummary(_ text: String) -> String {
        let characters = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let lines = text.isEmpty ? 0 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        func plural(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }
        return [plural(characters, "character"), plural(words, "word"), plural(lines, "line")].joined(separator: " · ")
    }

    private static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }
}
