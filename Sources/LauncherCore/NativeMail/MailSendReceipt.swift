import Foundation

/// SMTP acceptance and filing in Sent are separate operations. A filing failure never resends.
public struct MailSendReceipt: Codable, Sendable, Equatable {
    public enum SentCopy: String, Codable, Sendable { case saved, serverManaged, pending }
    public let accountID: String
    public let messageID: String
    public let sentCopy: SentCopy
    public let note: String?
    /// Kept only while the accepted message needs a copy in Sent.
    public let message: Data?
    public let date: Date
    /// The mapped Sent mailbox observed immediately before a filing APPEND, when one was attempted.
    /// These fields let repair search only the UID interval that this APPEND could have changed.
    public let sentMailbox: String?
    public let sentUIDValidity: UInt32?
    public let sentUIDNext: UInt32?
    /// False means SMTP was accepted but no APPEND was attempted, such as missing or ambiguous
    /// Sent mapping. Nil is retained for older receipts and server-managed copies.
    public let filingAttempted: Bool?
    /// The sender identity accepted by the native boundary. Nil is retained for older receipts
    /// and receipts created directly by lower-level tests or integrations.
    public let sender: NativeMailSender?

    public init(accountID: String, messageID: String, sentCopy: SentCopy, note: String? = nil, message: Data? = nil,
                date: Date = Date(), sentMailbox: String? = nil, sentUIDValidity: UInt32? = nil,
                sentUIDNext: UInt32? = nil, filingAttempted: Bool? = nil, sender: NativeMailSender? = nil) {
        self.accountID = accountID; self.messageID = messageID; self.sentCopy = sentCopy
        self.note = note; self.message = message; self.sentMailbox = sentMailbox
        self.sentUIDValidity = sentUIDValidity; self.sentUIDNext = sentUIDNext
        self.filingAttempted = filingAttempted; self.sender = sender; self.date = date
    }
}
