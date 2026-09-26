import Foundation

/// A small TOML subset: top-level `key = value` with strings, integers, and booleans.
/// Tables, arrays, floats, and dates are refused with an error, never guessed.
public enum TomlValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case bool(Bool)
}

public struct TomlError: Error, Equatable, CustomStringConvertible, Sendable {
    public var line: Int
    public var message: String
    public var description: String { "Line \(line): \(message)" }
}

public enum TomlLite {
    public static func parse(_ text: String) throws -> [String: TomlValue] {
        var p = Parser(chars: Array(text.unicodeScalars))
        return try p.document()
    }
}

private struct Parser {
    let chars: [Unicode.Scalar]
    var i = 0
    var line = 1

    init(chars: [Unicode.Scalar]) { self.chars = chars }

    private var peek: Unicode.Scalar? { i < chars.count ? chars[i] : nil }
    private func fail(_ message: String) -> TomlError { TomlError(line: line, message: message) }

    private mutating func advance() -> Unicode.Scalar? {
        guard i < chars.count else { return nil }
        let c = chars[i]; i += 1
        if c == "\n" { line += 1 }
        return c
    }

    private func has(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard i + u.count <= chars.count else { return false }
        return Array(chars[i..<(i + u.count)]) == u
    }

    private mutating func skipSpaces() { while let c = peek, c == " " || c == "\t" { i += 1 } }

    /// Spaces, then an optional comment, then a newline or the end.
    private mutating func endOfLine() throws {
        skipSpaces()
        if peek == "#" { while let c = peek, c != "\n" { i += 1 } }
        if peek == "\r" { i += 1 }
        guard peek == nil || peek == "\n" else { throw fail("Unexpected text after value") }
        _ = advance()
    }

    mutating func document() throws -> [String: TomlValue] {
        var result: [String: TomlValue] = [:]
        while peek != nil {
            skipSpaces()
            guard let c = peek else { break }
            if c == "\n" || c == "#" || c == "\r" { try endOfLine(); continue }
            if c == "[" { throw fail("Tables are not supported") }
            let key = try parseKey()
            skipSpaces()
            guard advance() == "=" else { throw fail("Expected = after key") }
            skipSpaces()
            let value = try parseValue()
            guard result[key] == nil else { throw fail("Duplicate key \(key)") }
            result[key] = value
            try endOfLine()
        }
        return result
    }

    private mutating func parseKey() throws -> String {
        if peek == "\"" { _ = advance(); return try basicString() }
        var s = ""
        while let c = peek, c.isASCII && (Character(c).isLetter || Character(c).isNumber || c == "_" || c == "-") {
            s.unicodeScalars.append(c); i += 1
        }
        if peek == "." { throw fail("Dotted keys are not supported") }
        guard !s.isEmpty else { throw fail("Expected a key") }
        return s
    }

    private mutating func parseValue() throws -> TomlValue {
        guard let c = peek else { throw fail("Missing value") }
        if has("\"\"\"") { i += 3; return .string(try multilineBasic()) }
        if has("'''") { throw fail("Multi-line literal strings are not supported") }
        if c == "\"" { _ = advance(); return .string(try basicString()) }
        if c == "'" { _ = advance(); return .string(try literalString()) }
        if c == "[" { throw fail("Arrays are not supported") }
        if c == "{" { throw fail("Inline tables are not supported") }
        var word = ""
        while let c = peek, !(c == " " || c == "\t" || c == "\n" || c == "\r" || c == "#") { word.unicodeScalars.append(c); i += 1 }
        if word == "true" { return .bool(true) }
        if word == "false" { return .bool(false) }
        return .integer(try integer(word))
    }

    private func integer(_ word: String) throws -> Int64 {
        var body = Substring(word)
        var sign: Int64 = 1
        if body.first == "+" || body.first == "-" { if body.first == "-" { sign = -1 }; body = body.dropFirst() }
        // Underscores only between digits; no leading zeros.
        guard !body.isEmpty, body.first != "_", body.last != "_", !body.contains("__"),
              body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "_") }),
              body == "0" || body.first != "0",
              let v = Int64(body.replacingOccurrences(of: "_", with: "")) else {
            throw fail("Unsupported value \(word.prefix(20))")
        }
        return sign * v
    }

    private mutating func basicString() throws -> String {
        var s = ""
        while true {
            guard let c = advance() else { throw fail("Unterminated string") }
            switch c {
            case "\"": return s
            case "\n": throw fail("Newline in string")
            case "\\": s.unicodeScalars.append(try escape())
            default:
                if c.value < 0x20 && c != "\t" || c.value == 0x7F { throw fail("Control character in string") }
                s.unicodeScalars.append(c)
            }
        }
    }

    private mutating func escape() throws -> Unicode.Scalar {
        guard let e = advance() else { throw fail("Unterminated escape") }
        switch e {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u": return try hexScalar(4)
        case "U": return try hexScalar(8)
        default: throw fail("Unknown escape \\\(e)")
        }
    }

    private mutating func hexScalar(_ count: Int) throws -> Unicode.Scalar {
        var hex = ""
        for _ in 0..<count {
            guard let c = advance(), c.properties.isASCIIHexDigit else { throw fail("Bad unicode escape") }
            hex.unicodeScalars.append(c)
        }
        guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { throw fail("Bad unicode escape") }
        return scalar
    }

    private mutating func literalString() throws -> String {
        var s = ""
        while true {
            guard let c = advance() else { throw fail("Unterminated string") }
            if c == "'" { return s }
            if c == "\n" { throw fail("Newline in string") }
            s.unicodeScalars.append(c)
        }
    }

    private mutating func multilineBasic() throws -> String {
        // A newline right after the opening quotes is trimmed.
        if peek == "\n" { _ = advance() } else if has("\r\n") { i += 1; _ = advance() }
        var s = ""
        while true {
            if has("\"\"\"") {
                i += 3
                // Up to two extra quotes belong to the content.
                var extra = 0
                while peek == "\"" && extra < 2 { s.append("\""); i += 1; extra += 1 }
                return s
            }
            guard let c = advance() else { throw fail("Unterminated multi-line string") }
            if c == "\\" {
                // Line-ending backslash trims the newline and following whitespace.
                var j = i
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                if j < chars.count, chars[j] == "\n" || chars[j] == "\r" {
                    while let w = peek, w == " " || w == "\t" || w == "\n" || w == "\r" { _ = advance() }
                } else {
                    s.unicodeScalars.append(try escape())
                }
            } else {
                s.unicodeScalars.append(c)
            }
        }
    }
}
