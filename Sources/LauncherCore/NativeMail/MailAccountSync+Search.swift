import Foundation

/// One bounded page of server-side search. A cursor is the next UID (exclusive upper bound) to
/// inspect for each mailbox. A value of zero means that mailbox reached UID 1. Callers pass the
/// returned map back unchanged for continuation; a changed UIDVALIDITY throws before any old
/// cursor is used.
public struct MailServerSearchPage: Sendable, Equatable {
    public let rowIDs: [Int64]
    public let cursors: [Int64: UInt32]
    /// The UIDVALIDITY observed by SELECT for each mailbox in this page. Callers must pass this
    /// map back with continuation cursors; a cursor without its original validity is unsafe after
    /// a mailbox reset.
    public let validities: [Int64: UInt32]
    public let complete: Bool

    public init(rowIDs: [Int64], cursors: [Int64: UInt32], validities: [Int64: UInt32] = [:], complete: Bool) {
        self.rowIDs = rowIDs
        self.cursors = cursors
        self.validities = validities
        self.complete = complete
    }
}

extension MailAccountSync {
    /// Searches selected server mailboxes without first downloading every header/body. Each
    /// SEARCH names one bounded UID range, and matching headers are saved to the native store so
    /// the returned row IDs are immediately usable by the local reader.
    public func search(mailboxIDs: [Int64], text: String, unreadOnly: Bool = false,
                       flaggedOnly: Bool = false, cursors: [Int64: UInt32] = [:],
                       validities: [Int64: UInt32] = [:], limit: Int = 200) async throws -> MailServerSearchPage {
        let boundedLimit = max(1, min(limit, 200))
        let requested = Array(Set(mailboxIDs)).sorted()
        guard !requested.isEmpty else { return MailServerSearchPage(rowIDs: [], cursors: [:], complete: true) }

        var boxes: [NativeMailStore.Mailbox] = []
        for rowID in requested {
            guard let box = try await store.mailbox(rowID), box.account == account.id else { continue }
            boxes.append(box)
        }
        guard !boxes.isEmpty else { return MailServerSearchPage(rowIDs: [], cursors: [:], complete: true) }

        // A cursor is meaningful only with the UIDVALIDITY observed when that cursor was made.
        // Refuse a cursor-only continuation instead of risking a search against renumbered mail.
        for box in boxes where cursors[box.rowID] != nil && validities[box.rowID] == nil {
            throw MailError.unexpected("A server search cursor for \(box.name) has no UIDVALIDITY.")
        }

        // SELECT every requested mailbox before consuming any cursor. This both validates the
        // caller's continuation identity and returns an identity for every selected scope, even
        // when another mailbox fills the page first.
        var selected: [Int64: IMAPClient.MailboxInfo] = [:]
        var selectedValidities: [Int64: UInt32] = [:]
        for box in boxes {
            try Task.checkCancellation()
            let info = try await actionClient.select(box.name)
            if let stored = box.uidValidity, stored != info.uidValidity {
                throw MailError.uidValidityChanged(mailbox: box.name)
            }
            if let expected = validities[box.rowID], expected != info.uidValidity {
                throw MailError.uidValidityChanged(mailbox: box.name)
            }
            // A server-search fetch is allowed to be the first work in a folder. Persist only
            // UIDVALIDITY so a later body fetch is safe; leave UIDNEXT and completion untouched so
            // the next normal sync still reads every newer header instead of treating search hits
            // as a complete initial sync.
            if box.uidValidity == nil {
                try await store.setUIDValidity(box.rowID, info.uidValidity)
                var initialized = box
                initialized.uidValidity = info.uidValidity
                replace(initialized)
            }
            selected[box.rowID] = info
            selectedValidities[box.rowID] = info.uidValidity
        }

        var next = Dictionary(uniqueKeysWithValues: boxes.map { ($0.rowID, cursors[$0.rowID] ?? UInt32.max) })
        var finished = Set<Int64>()
        var rowIDs: [Int64] = []
        var rounds = 0
        let maxRounds = 8
        // Without UIDONLY, MESSAGELIMIT may describe a partial server view even after the cursor
        // reaches zero. Keep that uncertainty attached to every continuation page, including a
        // cursor=0 call, so completion cannot flip from false to true on the next request.
        let serverUsesUIDOnly = await actionClient.uidOnly
        let advertisedMessageLimit = await actionClient.messageLimit
        let uncertain = !serverUsesUIDOnly && advertisedMessageLimit != nil
        var stopPage = false

        // One range per mailbox per round keeps a combined scope fair and makes cancellation
        // observable even when the first mailbox contains millions of old messages.
        while rowIDs.count < boundedLimit, rounds < maxRounds, finished.count < boxes.count {
            rounds += 1
            var madeProgress = false
            for box in boxes {
                try Task.checkCancellation()
                guard rowIDs.count < boundedLimit, !finished.contains(box.rowID) else { continue }
                guard let info = selected[box.rowID] else { continue }
                let validity = info.uidValidity
                let top = next[box.rowID] ?? UInt32.max
                guard top > 0 else { finished.insert(box.rowID); continue }
                let upper: UInt32
                if top == UInt32.max {
                    guard let nextUID = info.uidNext else {
                        throw MailError.unexpected("The server did not provide UIDNEXT for \(box.name).")
                    }
                    upper = nextUID > 0 ? nextUID - 1 : 0
                } else { upper = top }
                guard upper > 0 else { next[box.rowID] = 0; finished.insert(box.rowID); continue }
                let range = try await searchRange(upper: upper, mailbox: box.name, validity: validity,
                                                  text: text, unreadOnly: unreadOnly, flaggedOnly: flaggedOnly)
                let lower = range.low
                let hits = range.uids
                if !hits.isEmpty {
                    // Do not cache every match in the search window when the page is full.
                    // Only headers that can be returned belong in this bounded result; the
                    // continuation cursor resumes below the last UID selected here.
                    let pageHits = Array(hits.prefix(max(1, boundedLimit - rowIDs.count)))
                    var selected = box
                    selected.uidValidity = validity
                    try await fetchHeaders(pageHits, into: selected, validity: validity,
                                           items: SyncedMessage.fetchItems(gmail: await actionClient.has("X-GM-EXT-1")),
                                           client: actionClient)
                    var lastReturnedUID: UInt32?
                    for uid in pageHits {
                        if let rowID = try await store.rowID(uid: uid, in: box.rowID), !rowIDs.contains(rowID) {
                            rowIDs.append(rowID)
                            lastReturnedUID = uid
                            if rowIDs.count == boundedLimit { break }
                        }
                    }
                    if rowIDs.count == boundedLimit {
                        // The range may contain more matches than this page can return. Continue
                        // below the last returned UID so no matching header is skipped.
                        let cursor = lastReturnedUID.map { $0 > 0 ? $0 - 1 : 0 } ?? lower
                        next[box.rowID] = cursor
                        if cursor == 0 { finished.insert(box.rowID) }
                        stopPage = true
                    }
                }
                if stopPage { madeProgress = true; break }
                let newCursor = lower == 1 ? 0 : lower - 1
                next[box.rowID] = newCursor
                if newCursor == 0 { finished.insert(box.rowID) }
                madeProgress = true
            }
            if stopPage { break }
            if !madeProgress { break }
        }
        let complete = finished.count == boxes.count && !uncertain
        return MailServerSearchPage(rowIDs: rowIDs, cursors: next, validities: selectedValidities, complete: complete)
    }

    private func searchRange(upper: UInt32, mailbox: String, validity: UInt32, text: String,
                             unreadOnly: Bool, flaggedOnly: Bool) async throws -> (low: UInt32, uids: [UInt32]) {
        let advertised = max(await actionClient.messageLimit ?? max(policy.searchBatch, 1), 1)
        var span = UInt32(clamping: min(max(policy.searchBatch, 1), advertised))
        while true {
            try Task.checkCancellation()
            let low = upper >= span ? upper - span + 1 : 1
            do {
                let found = try await actionClient.search(uids: low...upper, text: text.isEmpty ? nil : text,
                                                          unreadOnly: unreadOnly, flaggedOnly: flaggedOnly,
                                                          in: mailbox, validity: validity)
                return (low, found.numbers.filter { $0 >= low && $0 <= upper }.sorted(by: >))
            } catch MailError.commandFailed(_, .no, _) where span > 1 {
                span = max(1, span / 2)
            }
        }
    }
}
