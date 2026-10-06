import Foundation

extension NativeMailEngine {
    /// Searches selected account folders in bounded pages. Bodies stay on the server until opened.
    public func search(mailboxIDs: [Int64], text: String, unreadOnly: Bool = false,
                       flaggedOnly: Bool = false, cursors: [Int64: UInt32] = [:],
                       validities: [Int64: UInt32] = [:], limit: Int = 200) async throws -> MailServerSearchPage {
        var grouped: [String: [Int64]] = [:]
        for id in Set(mailboxIDs) {
            if let box = try await store.mailbox(id) { grouped[box.account, default: []].append(id) }
        }
        var rows: [Int64] = [], next = cursors, identity = validities
        var complete = true
        for account in grouped.keys.sorted() {
            try Task.checkCancellation()
            guard rows.count < max(1, limit) else { complete = false; break }
            let sync = try accountSync(account)
            let page = try await sync.search(mailboxIDs: grouped[account] ?? [], text: text,
                                             unreadOnly: unreadOnly, flaggedOnly: flaggedOnly,
                                             cursors: cursors, validities: validities,
                                             limit: max(1, min(200, limit - rows.count)))
            rows += page.rowIDs
            next.merge(page.cursors) { _, new in new }
            identity.merge(page.validities) { _, new in new }
            complete = complete && page.complete
        }
        return .init(rowIDs: rows, cursors: next, validities: identity, complete: complete)
    }
}
