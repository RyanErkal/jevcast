import CryptoKit
import Foundation

/// The server identity of one draft Jevcast appended to the account's mapped Drafts mailbox.
///
/// The mailbox row is local to this store. The account, UIDVALIDITY, UID, Message-ID, and body
/// digest together make a reference safe to use for an exact later edit or removal.
public struct MailServerDraftReference: Codable, Sendable, Equatable {
    public let accountID: String
    public let mailboxID: Int64
    public let uidValidity: UInt32
    public let uid: UInt32
    public let messageID: String
    public let digest: String

    public init(accountID: String, mailboxID: Int64, uidValidity: UInt32, uid: UInt32,
                messageID: String, digest: String) {
        self.accountID = accountID
        self.mailboxID = mailboxID
        self.uidValidity = uidValidity
        self.uid = uid
        self.messageID = messageID
        self.digest = digest
    }
}

/// A bounded, recoverable failure while saving or removing an owned server draft.
public enum MailServerDraftError: Error, LocalizedError, Equatable, Sendable {
    case draftsMailboxMissing(accountID: String)
    case draftsMailboxNotUnique(accountID: String)
    case uidPlusRequired
    case draftsMailboxReadOnly
    case invalidMessageID
    case messageIDMismatch(expected: String, found: String?)
    case invalidReference
    case referenceAccountMismatch
    case referenceMailboxMismatch
    case referenceUIDValidityChanged(expected: UInt32, actual: UInt32?)
    case referenceNotFound(MailServerDraftReference)
    case ownedDraftChanged(MailServerDraftReference)
    case appendAcknowledgementUncertain(mailbox: String, uidValidity: UInt32)
    case acknowledgementUncertain(messageID: String, digest: String,
                                   candidate: MailServerDraftReference?, replacing: MailServerDraftReference?)
    case removalUncertain(MailServerDraftReference)
    case partialReplacement(previous: MailServerDraftReference, new: MailServerDraftReference, reason: String)
    case reconciliationBoundExceeded

    public var errorDescription: String? {
        switch self {
        case .draftsMailboxMissing:
            return "Choose one server Drafts folder in Settings › Mail before saving a draft."
        case .draftsMailboxNotUnique:
            return "Choose exactly one server Drafts folder in Settings › Mail before saving a draft."
        case .uidPlusRequired:
            return "This mail server does not support safe draft replacement or removal (UIDPLUS). No change was made."
        case .draftsMailboxReadOnly:
            return "The server Drafts folder is read only. No change was made."
        case .invalidMessageID:
            return "This draft has no valid generated Message-ID. No server draft was changed."
        case let .messageIDMismatch(expected, found):
            return "The draft Message-ID does not match the requested draft (expected \(expected), found \(found ?? "none"))."
        case .invalidReference:
            return "This saved server-draft reference is incomplete. The server draft was not changed."
        case .referenceAccountMismatch:
            return "This server draft belongs to another account. No change was made."
        case .referenceMailboxMismatch:
            return "This server draft is not in the account's mapped Drafts folder. No change was made."
        case let .referenceUIDValidityChanged(expected, actual):
            return "The server renumbered the Drafts folder (expected UIDVALIDITY \(expected), found \(actual.map(String.init) ?? "another value")). Open the draft again."
        case .referenceNotFound:
            return "The owned server draft is no longer present. No other draft was changed."
        case .ownedDraftChanged:
            return "The server draft changed outside Jevcast. It was not removed."
        case .appendAcknowledgementUncertain:
            return "The mail server may have saved this draft, but its APPEND acknowledgement was lost. Review Drafts before trying again."
        case .acknowledgementUncertain:
            return "The mail server may have saved this draft, but Jevcast could not prove its UID. Review Drafts before trying again."
        case .removalUncertain:
            return "The server may have removed this draft, but its acknowledgement was lost. Review Drafts before trying again."
        case let .partialReplacement(_, _, reason):
            return "The new draft was saved, but the old draft was not removed (\(reason)). Both references are kept for recovery."
        case .reconciliationBoundExceeded:
            return "The server returned too many possible drafts to reconcile safely. Review Drafts before trying again."
        }
    }
}

enum MailServerDraftSupport {
    static func digest(_ raw: Data) -> String {
        SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts the generated, angle-bracketed form used by MailComposer. Deliberately rejects
    /// quoting, controls, and whitespace so it can be placed in an exact bounded IMAP SEARCH.
    static func validMessageID(_ value: String) -> Bool {
        guard value.count <= 998, value.first == "<", value.last == ">", value.count > 3,
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\"" || $0 == "\\" || $0 == "\0" }) else { return false }
        let body = value.dropFirst().dropLast()
        guard let at = body.firstIndex(of: "@"), at != body.startIndex, at != body.index(before: body.endIndex) else { return false }
        return body[body.index(after: at)...].contains(where: { $0 == "." || $0.isLetter || $0.isNumber })
    }

    static func errorText(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        return String(describing: error)
    }
}
