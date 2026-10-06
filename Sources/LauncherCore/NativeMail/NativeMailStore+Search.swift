import Foundation

extension NativeMailStore {
    /// A bounded local search result. The index covers every header/body row downloaded to this
    /// Mac, while `complete` reports whether the bounded query read the whole selected scope.
    public struct IndexedSearchPage: Sendable, Equatable {
        public let rowIDs: [Int64]
        public let complete: Bool

        public init(rowIDs: [Int64], complete: Bool = true) {
            self.rowIDs = rowIDs
            self.complete = complete
        }
    }

    /// Searches Jevcast's private FTS index. The query never touches an Apple Mail index, and the
    /// filters are applied to the canonical message table so local flag changes are immediate.
    /// When several selected mailboxes contain one message, the preferred copy wins and the rest
    /// are dropped, matching unified-list behaviour.
    public func search(mailboxIDs: [Int64], text: String, unreadOnly: Bool = false,
                       flaggedOnly: Bool = false, limit: Int = 200,
                       preferredMailboxIDs: Set<Int64> = []) throws -> IndexedSearchPage {
        let boxes = Array(Set(mailboxIDs)).sorted()
        guard !boxes.isEmpty else { return IndexedSearchPage(rowIDs: []) }
        let bounded = max(1, min(limit, 2_000))
        let mailboxList = boxes.map { _ in "?" }.joined(separator: ",")
        var arguments: [MailDatabase.Value] = boxes.map { .int($0) }
        var whereParts = ["m.deleted = 0", "m.mailbox IN (" + mailboxList + ")"]
        if unreadOnly { whereParts.append("m.read = 0") }
        if flaggedOnly { whereParts.append("m.flagged = 1") }

        let query = Self.ftsQuery(text)
        let join: String
        if let query {
            join = "JOIN messages_fts f ON f.rowid = m.ROWID"
            // FTS5 requires the declared table name on the left of MATCH, even when the table
            // is joined through an alias.
            whereParts.append("messages_fts MATCH ?")
            // The MATCH parameter follows mailbox IDs and the other predicates' parameters.
            arguments.append(.text(query))
        } else {
            join = ""
        }

        let preferred = preferredMailboxIDs.intersection(boxes)
        let preferredSQL: String
        if preferred.isEmpty {
            // A bare zero is interpreted as a column ordinal by SQLite.
            preferredSQL = "CASE WHEN m.mailbox = m.mailbox THEN 0 ELSE 1 END"
        } else {
            preferredSQL = "CASE WHEN m.mailbox IN (" + preferred.map { _ in "?" }.joined(separator: ",") + ") THEN 0 ELSE 1 END"
            arguments.append(contentsOf: preferred.sorted().map { .int($0) })
        }

        // Read a bounded candidate window, but always leave room to observe one distinct
        // match beyond the requested page. `complete` must be false when deduplication
        // drops a second match even if the SQL window itself was not filled.
        let candidateLimit = max(bounded * 4, bounded + 1)
        let sql = "SELECT m.ROWID, COALESCE(m.global_message_id, 0), COALESCE(m.message_id, 0), "
            + "m.date_received FROM messages m " + join
            + " WHERE " + whereParts.joined(separator: " AND ")
            + " ORDER BY " + preferredSQL + ", m.date_received DESC, m.ROWID DESC LIMIT ?"
        arguments.append(.int(Int64(candidateLimit)))
        let rows = try db.rows(sql, arguments)

        // Keep one row per message key. Prefer the selected inbox/label copy, then newest.
        var seen: Set<String> = []
        var result: [Int64] = []
        var hasExtraDistinct = false
        for row in rows {
            guard row.count >= 3, let rowID = row[0].int else { continue }
            let global = row[1].int ?? 0
            let message = row[2].int ?? 0
            let key = global != 0 ? "g:\(global)" : (message != 0 ? "m:\(message)" : "r:\(rowID)")
            guard seen.insert(key).inserted else { continue }
            if result.count < bounded { result.append(rowID) }
            else { hasExtraDistinct = true }
        }
        // A candidate page that filled its bounded window may have more matches after dedupe.
        // Reaching the candidate bound also leaves unseen rows, so only a short scan with no
        // extra distinct match proves that this indexed scope is exhausted.
        return IndexedSearchPage(rowIDs: result, complete: !hasExtraDistinct && rows.count < candidateLimit)
    }

    /// Convenience form used by non-UI callers that only need row IDs.
    public func searchIndexed(mailboxIDs: [Int64], text: String, unreadOnly: Bool = false,
                              flaggedOnly: Bool = false, limit: Int = 200,
                              preferredMailboxIDs: Set<Int64> = []) throws -> [Int64] {
        try search(mailboxIDs: mailboxIDs, text: text, unreadOnly: unreadOnly,
                   flaggedOnly: flaggedOnly, limit: limit,
                   preferredMailboxIDs: preferredMailboxIDs).rowIDs
    }

    /// Rebuilds one FTS row after a header or body write. This is actor-isolated and is called
    /// inside the caller's SQLite transaction, so a cancelled/failed write cannot leave a stale
    /// row visible to a later search.
    func updateSearchIndex(_ rowID: Int64) throws {
        guard let row = try db.rows("""
            SELECT m.mailbox, COALESCE(s.subject, ''),
                   TRIM(COALESCE(a.comment, '') || ' ' || COALESCE(a.address, '')),
                   COALESCE(b.summary, '')
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN summaries b ON b.ROWID = m.summary
            WHERE m.ROWID = ?
            """, [.int(rowID)]).first, row.count == 4 else { return }
        try db.run("DELETE FROM messages_fts WHERE rowid = ?", [.int(rowID)])
        try db.run("""
            INSERT INTO messages_fts (rowid, row_id, mailbox, subject, sender, body) VALUES (?, ?, ?, ?, ?, ?)
            """, [.int(rowID), .int(rowID), row[0].int.map { .int($0) } ?? .null, .text(row[1].text ?? ""),
                  .text(row[2].text ?? ""), .text(row[3].text ?? "")])
    }

    private static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        // Quoting each token turns punctuation/operators into data, not FTS syntax. A trailing
        // prefix wildcard keeps incremental search useful while still requiring every token.
        let terms = words.prefix(12).map { word in
            let escaped = word.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }
        return terms.joined(separator: " AND ")
    }
}
