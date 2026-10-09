import Foundation

public enum MailOfflineActionKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case read
    case flag
    case archive
    case move
}

public enum MailOfflineActionState: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case pending
    case failed
    case review

    public var title: String {
        switch self {
        case .pending: return "Waiting to sync"
        case .failed: return "Sync failed"
        case .review: return "Needs review"
        }
    }
}

/// A durable, identity-bound change. There is deliberately no permanent-delete case.
public struct MailOfflineAction: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let accountID: String
    public let kind: MailOfflineActionKind
    public let mailboxName: String
    public let uidValidity: UInt32
    public let uid: UInt32
    public let messageID: String?
    public let destinationMailboxName: String?
    public let destinationUIDValidity: UInt32?
    public var desiredValue: Bool?
    public var state: MailOfflineActionState
    public var attempts: Int
    public var lastError: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), accountID: String, kind: MailOfflineActionKind,
                mailboxName: String, uidValidity: UInt32, uid: UInt32, messageID: String? = nil,
                destinationMailboxName: String? = nil, destinationUIDValidity: UInt32? = nil,
                desiredValue: Bool? = nil, state: MailOfflineActionState = .pending,
                attempts: Int = 0, lastError: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.accountID = accountID; self.kind = kind
        self.mailboxName = mailboxName; self.uidValidity = uidValidity; self.uid = uid
        self.messageID = messageID; self.destinationMailboxName = destinationMailboxName
        self.destinationUIDValidity = destinationUIDValidity; self.desiredValue = desiredValue
        self.state = state; self.attempts = max(0, attempts); self.lastError = lastError
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct MailOfflineQueueStatus: Equatable, Sendable {
    public let pending: Int
    public let failed: Int
    public let review: Int
    public let lastError: String?

    public init(pending: Int = 0, failed: Int = 0, review: Int = 0, lastError: String? = nil) {
        self.pending = pending; self.failed = failed; self.review = review; self.lastError = lastError
    }

    public var total: Int { pending + failed + review }
}
