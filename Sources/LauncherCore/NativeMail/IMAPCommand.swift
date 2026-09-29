import Foundation

/// An IMAP command as the client writes it. Strings go as atoms when they can, quoted when they
/// must, and as literals when they hold line breaks or 8-bit text, so a value can never end the
/// line early or add a command of its own.
public struct IMAPCommand: Sendable {
    public enum Part: Sendable, Equatable { case text(String), literal(Data) }
    public private(set) var parts: [Part]
    /// The command word, for errors. Never its arguments, which can hold a password.
    public let name: String

    public init(_ name: String) { self.name = name; parts = [.text(name)] }

    /// Text written as is, after a space: numbers, sets, and fixed item lists.
    public func raw(_ text: String) -> IMAPCommand { var copy = self; copy.parts.append(.text(text)); return copy }

    /// A string argument (IMAP astring).
    public func string(_ value: String) -> IMAPCommand {
        switch Self.form(of: value) {
        case .atom: return raw(value)
        case .quoted: return raw(Self.quoted(value))
        case .literal: return literal(Data(value.utf8))
        }
    }

    /// A mailbox name in modified UTF-7. INBOX is always written as INBOX.
    public func mailbox(_ name: String) -> IMAPCommand {
        string(name.caseInsensitiveCompare("INBOX") == .orderedSame ? "INBOX" : ModifiedUTF7.encode(name))
    }

    public func literal(_ data: Data) -> IMAPCommand { var copy = self; copy.parts.append(.literal(data)); return copy }

    enum Form { case atom, quoted, literal }
    static func form(of value: String) -> Form {
        guard !value.isEmpty else { return .quoted }
        let bytes = Array(value.utf8)
        if bytes.contains(where: { $0 == Byte.cr || $0 == Byte.lf || $0 == 0 || $0 >= 0x80 }) { return .literal }
        let safe = bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || [0x2E, 0x2D, 0x5F, 0x2F, 0x2B, 0x40, 0x3A, 0x2C, 0x26, 0x24, 0x21, 0x23, 0x3D].contains(byte)
        }
        return safe ? .atom : .quoted
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// One write, and whether the server must answer "+" before the next write.
    public struct Segment: Equatable, Sendable {
        public let data: Data
        public let waitsForContinuation: Bool
    }

    /// The command as writes. With LITERAL+ it is one write; without it each literal waits for
    /// the server's go-ahead.
    public func segments(tag: String, literalPlus: Bool) -> [Segment] {
        var segments: [Segment] = []
        var current = Data((tag + " ").utf8)
        for (index, part) in parts.enumerated() {
            switch part {
            case .text(let text):
                if index > 0 { current.append(Byte.space) }
                current.append(contentsOf: text.utf8)
            case .literal(let data):
                if index > 0 { current.append(Byte.space) }
                current.append(contentsOf: "{\(data.count)\(literalPlus ? "+" : "")}\r\n".utf8)
                if literalPlus { current.append(data); continue }
                segments.append(Segment(data: current, waitsForContinuation: true))
                current = data
            }
        }
        current.append(contentsOf: "\r\n".utf8)
        segments.append(Segment(data: current, waitsForContinuation: false))
        return segments
    }
}
