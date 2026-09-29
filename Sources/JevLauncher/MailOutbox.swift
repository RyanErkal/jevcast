import Foundation

/// Apple Mail's Outbox. Mail's `send` only puts a message there, and Mail delivers it a moment later.
/// Quitting Mail before then can leave the message unsent, or make Mail ask about it.
enum MailOutbox {
    /// Waits until the Outbox is empty: `tries` counts, `interval` seconds apart, about a minute by
    /// default. Returns false when it still holds mail at the end. A count that fails (nil) keeps the
    /// last one read. When Mail gives none at all, the Outbox counts as empty, so Mail quits as before.
    static func waitUntilEmpty(tries: Int = 30, interval: TimeInterval = 2,
                               count: () async -> Int? = { await MailActions.outboxCount() }) async -> Bool {
        var last: Int?
        for attempt in 0..<tries {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            if Task.isCancelled { break }
            last = await count() ?? last
            if last == 0 { return true }
        }
        return (last ?? 0) == 0
    }
}
