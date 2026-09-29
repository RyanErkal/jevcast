import Foundation

/// What a sync pass should look at. Requests that arrive while a pass runs merge into one.
public struct MailSyncRequest: Sendable, Equatable {
    /// Every mailbox, and the mailbox list itself.
    public var all = false
    public var inbox = false
    /// Specific mailboxes, such as the Archive a message just moved to.
    public var mailboxes: Set<Int64> = []
    /// Older mail and bodies, a step at a time, when nothing newer waits.
    public var backfill = false

    public init(all: Bool = false, inbox: Bool = false, mailboxes: Set<Int64> = [], backfill: Bool = false) {
        self.all = all; self.inbox = inbox; self.mailboxes = mailboxes; self.backfill = backfill
    }
    public static let everything = MailSyncRequest(all: true)
    public static let inboxOnly = MailSyncRequest(inbox: true)

    mutating func merge(_ other: MailSyncRequest) {
        all = all || other.all; inbox = inbox || other.inbox; backfill = backfill || other.backfill
        mailboxes.formUnion(other.mailboxes)
    }
}

/// Wakes the sync loop: a request, or nil when `wait` times out.
actor MailSyncSignal {
    private var pending: MailSyncRequest?
    private var waiter: (id: Int, continuation: CheckedContinuation<MailSyncRequest?, Never>)?
    private var nextID = 0

    func post(_ request: MailSyncRequest) {
        var merged = pending ?? MailSyncRequest()
        merged.merge(request)
        if let waiter {
            self.waiter = nil
            pending = nil
            waiter.continuation.resume(returning: merged)
        } else {
            pending = merged
        }
    }

    func wait(timeout: TimeInterval) async -> MailSyncRequest? {
        if let pending { self.pending = nil; return pending }
        nextID += 1
        let id = nextID
        return await withCheckedContinuation { continuation in
            waiter = (id, continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
                await self?.expire(id)
            }
        }
    }

    /// Ends a wait at once, for stopping.
    func cancel() { expire(waiter?.id ?? -1) }

    private func expire(_ id: Int) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}

/// How much sync reads and how often. Fixed numbers, chosen for a quick first list and steady,
/// light work after it.
public struct MailSyncPolicy: Sendable {
    /// Newest messages read first in a mailbox never synced before.
    public var firstInbox = 2500
    public var firstOther = 500
    /// Headers per FETCH, so the list fills in steps, newest first.
    public var headerBatch = 250
    /// Older messages per step once the newest are in.
    public var backfillBatch = 1000
    /// Bodies read ahead so messages open at once, and the largest read ahead.
    public var prefetchInbox = 150
    public var prefetchOther = 25
    public var prefetchMaxSize: Int64 = 3_000_000
    public var bodyBatch = 20
    /// A full pass over every mailbox, when IDLE reports nothing sooner.
    public var periodic: TimeInterval = 300
    /// Removed messages and flags in mailboxes other than the inbox.
    public var fullCheck: TimeInterval = 900
    /// The mailbox list itself.
    public var listing: TimeInterval = 1800
    /// IDLE is renewed well inside the 29 minutes RFC 2177 allows.
    public var idle: TimeInterval = 25 * 60
    /// Checks for new mail on servers without IDLE.
    public var poll: TimeInterval = 120

    public init() {}
}
