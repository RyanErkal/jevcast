import Foundation

/// One value in an IMAP server reply: an atom (numbers are atoms too), a string that arrived
/// quoted or as a literal, NIL, or a parenthesized list.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case nilValue
    case list([IMAPValue])

    /// An atom as written, or a string as UTF-8 text.
    public var text: String? {
        switch self {
        case .atom(let value): return value
        case .string(let data): return String(decoding: data, as: UTF8.self)
        default: return nil
        }
    }
    public var number: UInt64? { if case .atom(let value) = self { return UInt64(value) }; return nil }
    public var list: [IMAPValue]? { if case .list(let values) = self { return values }; return nil }
    public var data: Data? {
        switch self {
        case .string(let data): return data
        case .atom(let value): return Data(value.utf8)
        default: return nil
        }
    }
}

public enum IMAPStatus: String, Sendable, Equatable {
    case ok = "OK", no = "NO", bad = "BAD", preauth = "PREAUTH", bye = "BYE"
}

/// The bracketed code after a status, such as `[UIDVALIDITY 3857529045]`. The name is upper case.
public struct IMAPResponseCode: Equatable, Sendable {
    public let name: String
    public let values: [IMAPValue]
    public init(name: String, values: [IMAPValue]) { self.name = name; self.values = values }
    public var number: UInt64? { values.first?.number }
}

public struct IMAPStatusText: Equatable, Sendable {
    public let status: IMAPStatus
    public let code: IMAPResponseCode?
    public let text: String
    public init(status: IMAPStatus, code: IMAPResponseCode?, text: String) { self.status = status; self.code = code; self.text = text }
}

public enum IMAPResponse: Equatable, Sendable {
    case tagged(tag: String, IMAPStatusText)
    case untagged(IMAPUntagged)
    case continuation(String)
}

public enum IMAPUntagged: Equatable, Sendable {
    case status(IMAPStatusText)
    case capability([String])
    case list(IMAPListEntry)
    case flags([String])
    case exists(UInt32)
    case recent(UInt32)
    case expunge(UInt32)
    case fetch(sequence: UInt32, IMAPFetch)
    case search([UInt32], modSeq: UInt64?)
    case esearch(IMAPESearch)
    case vanished(earlier: Bool, IMAPSequenceSet)
    case enabled([String])
    case mailboxStatus(name: String, [String: UInt64])
    case other(String)
}

/// A `LIST` reply. `name` is decoded from modified UTF-7; `rawName` is what the server sent.
public struct IMAPListEntry: Equatable, Sendable {
    public let flags: [String]
    public let delimiter: String?
    public let name: String
    public let rawName: String
    public init(flags: [String], delimiter: String?, rawName: String) {
        self.flags = flags; self.delimiter = delimiter; self.rawName = rawName
        name = ModifiedUTF7.decode(rawName)
    }
    public func has(_ flag: String) -> Bool { flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame } }
    /// False for `\Noselect` and `\NonExistent` entries, which hold no messages.
    public var selectable: Bool { !has("\\Noselect") && !has("\\NonExistent") }
}

/// The parts of a `FETCH` reply that sync reads. `sections` holds `BODY[...]` data by the text
/// inside the brackets, upper case, such as "" for the whole message or "HEADER.FIELDS (FROM)".
public struct IMAPFetch: Equatable, Sendable {
    public var uid: UInt32?
    public var flags: [String]?
    public var internalDate: Date?
    public var size: UInt64?
    public var modSeq: UInt64?
    public var sections: [String: Data] = [:]
    public var gmailMessageID: UInt64?
    public var gmailThreadID: UInt64?
    public var gmailLabels: [String]?
    public init() {}

    /// The header bytes of a `BODY[HEADER...]` or `RFC822.HEADER` item.
    public var header: Data? { sections.first { $0.key.hasPrefix("HEADER") || $0.key == "RFC822.HEADER" }?.value }
    /// The whole message of a `BODY[]` or `RFC822` item.
    public var message: Data? { sections[""] ?? sections["RFC822"] }
    public func hasFlag(_ flag: String) -> Bool { flags?.contains { $0.caseInsensitiveCompare(flag) == .orderedSame } ?? false }
}

/// An `ESEARCH` reply (RFC 4731).
public struct IMAPESearch: Equatable, Sendable {
    public var uid = false
    public var all: IMAPSequenceSet?
    public var min: UInt32?
    public var max: UInt32?
    public var count: UInt32?
    public init() {}
}
