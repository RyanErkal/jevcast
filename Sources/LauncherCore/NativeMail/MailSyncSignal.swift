import Foundation

/// What a sync pass should look at. Requests that arrive while a pass runs merge into one.
/// An empty request reads ahead a few bodies and nothing else.
public struct MailSyncRequest: Sendable, Equatable {
    /// The mailbox list, the inbox, and every mailbox opened before.
    public var all = false
    public var inbox = false
    /// Specific mailboxes, such as a folder just opened or the Archive a message just moved to.
    public var mailboxes: Set<Int64> = []

    public init(all: Bool = false, inbox: Bool = false, mailboxes: Set<Int64> = []) {
        self.all = all; self.inbox = inbox; self.mailboxes = mailboxes
    }
    public static let everything = MailSyncRequest(all: true)
    public static let inboxOnly = MailSyncRequest(inbox: true)

    mutating func merge(_ other: MailSyncRequest) {
        all = all || other.all; inbox = inbox || other.inbox
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

/// How much sync reads and how often. Sync keeps only what the mail view shows: the newest mail
/// of the inbox and of folders you open. Older mail is read when the list scrolls to it.
public struct MailSyncPolicy: Sendable {
    /// Newest messages read in a mailbox never synced before.
    public var firstInbox = 500
    public var firstOther = 200
    /// Older messages read each time the list reaches the end of what this Mac has.
    public var olderBatch = 250
    /// Headers per FETCH, so the list fills in steps, newest first.
    public var headerBatch = 250
    /// Stored messages per flag and removal check, well inside a server's MESSAGELIMIT.
    public var checkBatch = 500
    /// Maximum UID range searched for one remote search step. It is reduced to the server's
    /// advertised MESSAGELIMIT and halved after a refusal.
    public var searchBatch = 200
    /// Inbox removal checks are less frequent than flag checks. IDLE and CONDSTORE still surface
    /// new mail and changed flags promptly between these passes.
    public var inboxFullCheck: TimeInterval = 30
    /// Inbox bodies read ahead so new mail opens at once, and the largest read ahead.
    /// Other bodies are read when opened.
    public var prefetchInbox = 30
    public var prefetchMaxSize: Int64 = 1_000_000
    public var bodyBatch = 10
    /// A pass over the inbox and opened folders, when IDLE reports nothing sooner.
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
