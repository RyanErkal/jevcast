import Foundation

/// A message as sync stores it: UID, flags, and the header fields the list and replies need.
public struct SyncedMessage: Sendable, Equatable {
    public var uid: UInt32
    public var read = false, flagged = false, answered = false, deleted = false
    /// When the server received it (INTERNALDATE). The list sorts by this, as Mail does.
    public var date: Date
    public var size: Int64 = 0
    public var subject = ""
    public var senderName = ""
    public var senderAddress = ""
    /// The Message-ID header with its angle brackets.
    public var messageID: String?
    /// Two copies of one email, such as in Inbox and All Mail, share this number.
    public var messageKey: Int64 = 0
    /// Gmail's own message number, which is the same in every mailbox, when known.
    public var globalKey: Int64 = 0
    public var conversation: Int64 = 0
    /// List-Unsubscribe or a bulk Precedence header: mail sent to many people.
    public var bulk = false

    /// The header fields sync asks for, besides flags and dates.
    public static let headerFields = "DATE FROM SUBJECT MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE PRECEDENCE"

    /// FETCH items for a list row. Gmail's items add its message and thread numbers.
    public static func fetchItems(gmail: Bool) -> String {
        "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (\(headerFields))]" + (gmail ? " X-GM-MSGID X-GM-THRID" : "") + ")"
    }

    public init(uid: UInt32, date: Date) { self.uid = uid; self.date = date }

    /// Nil when the reply has no UID, which a UID FETCH always has.
    public init?(fetch: IMAPFetch) {
        guard let uid = fetch.uid else { return nil }
        self.init(uid: uid, date: fetch.internalDate ?? Date())
        apply(flags: fetch.flags ?? [])
        size = Int64(clamping: fetch.size ?? 0)
        if let header = fetch.header {
            let headers = MIMEMessage.parseHeaders(header)
            func value(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
            subject = value("Subject") ?? ""
            if let from = value("From").flatMap({ MailAddress.list($0).first }) {
                senderName = from.name; senderAddress = from.address
            }
            messageID = value("Message-ID").flatMap(MailReplies.messageIDs)?.first
            let parents = (value("References").flatMap(MailReplies.messageIDs) ?? []) + (value("In-Reply-To").flatMap(MailReplies.messageIDs) ?? [])
            let root = parents.first ?? messageID
            conversation = root.map(Self.hash) ?? 0
            let precedence = value("Precedence")?.lowercased() ?? ""
            bulk = value("List-Unsubscribe") != nil || precedence == "bulk" || precedence == "list" || precedence == "junk"
        }
        messageKey = messageID.map(Self.hash) ?? 0
        if let gmail = fetch.gmailMessageID { globalKey = Int64(bitPattern: gmail) }
        if let thread = fetch.gmailThreadID { conversation = Int64(bitPattern: thread) }
    }

    public mutating func apply(flags: [String]) {
        let lower = Set(flags.map { $0.lowercased() })
        read = lower.contains("\\seen"); flagged = lower.contains("\\flagged")
        answered = lower.contains("\\answered"); deleted = lower.contains("\\deleted")
    }

    /// FNV-1a over the lower-case text; never 0, which means "no key" in the store.
    public static func hash(_ text: String) -> Int64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.lowercased().utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        let result = Int64(bitPattern: value)
        return result == 0 ? 1 : result
    }
}
