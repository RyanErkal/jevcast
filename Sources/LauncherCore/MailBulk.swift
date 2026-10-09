import Foundation

public enum MailBulkOperation: Sendable, Equatable, Hashable {
    case markRead(Bool)
    case flag(Bool)
    case archive
    case move(mailboxID: Int64)
    case trash
}

/// Immutable state reviewed by the user before a bulk operation runs.
public struct MailBulkSnapshot: Sendable, Equatable, Hashable {
    public let message: MailSummary
    public let sourceMailboxID: Int64
    public let accountID: String
    public let expectedMessageID: String?
    public let reviewedAt: Date

    public init(message: MailSummary, sourceMailboxID: Int64, accountID: String,
                expectedMessageID: String? = nil, reviewedAt: Date = Date()) {
        self.message = message; self.sourceMailboxID = sourceMailboxID; self.accountID = accountID
        self.expectedMessageID = expectedMessageID; self.reviewedAt = reviewedAt
    }
}

public struct MailBulkFailure: Sendable, Equatable, Hashable, Identifiable {
    public let snapshot: MailBulkSnapshot
    public let reason: String
    public var id: Int64 { snapshot.message.rowID }
    public init(snapshot: MailBulkSnapshot, reason: String) { self.snapshot = snapshot; self.reason = reason }
}

public struct MailBulkResult: Sendable, Equatable {
    public let operation: MailBulkOperation
    public let reviewed: [MailBulkSnapshot]
    public let succeeded: [MailBulkSnapshot]
    public let failures: [MailBulkFailure]
    public let undoable: [MailBulkSnapshot]

    public init(operation: MailBulkOperation, reviewed: [MailBulkSnapshot], succeeded: [MailBulkSnapshot] = [],
                failures: [MailBulkFailure] = [], undoable: [MailBulkSnapshot] = []) {
        self.operation = operation; self.reviewed = reviewed; self.succeeded = succeeded
        self.failures = failures; self.undoable = undoable
    }

    public var isPartialFailure: Bool { !failures.isEmpty && !succeeded.isEmpty }
    public var isCompleteFailure: Bool { !reviewed.isEmpty && succeeded.isEmpty && failures.count == reviewed.count }
}

/// Selection state kept separate from the reader's one-message selection.
public struct MailBulkSelection: Sendable, Equatable {
    public private(set) var ids: Set<Int64> = []
    public private(set) var anchorID: Int64?

    public init(ids: Set<Int64> = [], anchorID: Int64? = nil) { self.ids = ids; self.anchorID = anchorID }
    public mutating func clear() { ids.removeAll(); anchorID = nil }
    public mutating func replace(with ids: Set<Int64>, anchorID: Int64? = nil) { self.ids = ids; self.anchorID = anchorID }
    public mutating func toggle(_ id: Int64) {
        if !ids.insert(id).inserted { ids.remove(id) }
        anchorID = id
    }
    public mutating func add(_ id: Int64) { ids.insert(id); anchorID = id }
}
