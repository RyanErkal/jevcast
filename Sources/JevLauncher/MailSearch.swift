import Foundation
import LauncherCore

/// The second phase of a mail search: body text. Mail keeps a plain-text summary of each body,
/// often kilobytes long, and has no text index Jevcast can read, so a body search reads summaries.
/// It reads them newest first, a fixed window of rows at a time, and stops after a time budget or
/// enough matches. The list shows subject and sender matches first; body matches join it as they come.
extension MailStore {
    /// Rows read per step: small enough that one step stays a few milliseconds.
    static let bodyWindow = 2_000

    struct BodyResult: Equatable {
        var messages: [MailSummary]
        /// Where the next step starts: the oldest row read so far.
        var cursor: Cursor?
        /// True when every row in scope was read.
        var done: Bool
    }

    /// One window: the next `bodyWindow` rows in scope older than `before`, filtered so that every
    /// word appears in the subject, the sender, or the body summary.
    static func bodyStep(root: String, _ query: Query, before: Cursor?, stop: (() -> Bool)? = nil) throws -> BodyResult {
        try withIndex(root, stop: stop) { db, cols in
            guard Columns(cols).summary, !words(query.text).isEmpty else { return BodyResult(messages: [], cursor: before, done: true) }
            var windowQuery = query
            windowQuery.before = before
            windowQuery.after = nil
            guard let scope = scope(cols, windowQuery, limit: bodyWindow, match: false) else { return BodyResult(messages: [], cursor: before, done: true) }
            let with = "WITH " + (scope.ctes + ["win AS MATERIALIZED (\(scope.rows))"]).joined(separator: ", ") + "\n"
            // The window's oldest row is the next step's cursor; a short window is the last one.
            let edge = try db.rows(with + "SELECT id, d, (SELECT COUNT(*) FROM win) FROM win ORDER BY d ASC, id ASC LIMIT 1", scope.arguments).first
            guard let edge, edge.count == 3, let edgeID = edge[0].int else { return BodyResult(messages: [], cursor: before, done: true) }
            // Each word's pattern is argument ?N, N = word index + 1, as `scope` numbers them.
            let match = scope.words.indices.map { index in
                "(m.subject IN w\(index)s OR m.sender IN w\(index)a OR b.summary LIKE ?\(index + 1) ESCAPE '\\')"
            }.joined(separator: " AND ")
            let rows = try db.rows(with + """
            SELECT \(listColumns(cols, preview: query.includePreview))
            FROM win p
            JOIN messages m ON m.ROWID = p.id
            LEFT JOIN summaries b ON b.ROWID = m.summary
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            WHERE \(match)
            ORDER BY p.d DESC, p.id DESC
            """, scope.arguments)
            let kept = query.dedupe ? try canonicalRows(db, cols, query, rows) : rows
            let cursor = Cursor(date: edge[1].double ?? 0, rowID: edgeID)
            return BodyResult(messages: summaries(kept), cursor: cursor, done: (edge[2].int ?? 0) < bodyWindow)
        }
    }

    /// Steps through windows until `budget` seconds pass, `maxMatches` matches are found, or every
    /// row was read. A later call with the returned cursor goes on where this one stopped.
    static func searchBodies(root: String, _ query: Query, from cursor: Cursor? = nil, budget: TimeInterval = 0.15,
                             maxMatches: Int = 200, stop: (() -> Bool)? = nil) throws -> BodyResult {
        let start = CFAbsoluteTimeGetCurrent()
        var result = BodyResult(messages: [], cursor: cursor, done: false)
        repeat {
            let step = try bodyStep(root: root, query, before: result.cursor, stop: stop)
            result.messages += step.messages
            result.cursor = step.cursor
            result.done = step.done
        } while !result.done && result.messages.count < maxMatches && CFAbsoluteTimeGetCurrent() - start < budget
        return result
    }
}
