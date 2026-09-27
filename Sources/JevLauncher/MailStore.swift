import Foundation
import LauncherCore

/// Reads Apple Mail's own data, read-only: the `Envelope Index` database for lists and
/// `.emlx` files for bodies. Mail does not have to run for reading. Needs Full Disk Access.
enum MailStore {
    enum Status: Equatable {
        case ready(root: String)
        case needsFullDiskAccess
        case noMail
    }

    /// Where Mail keeps its data, and whether Jevcast may read it.
    static func status() -> Status {
        let base = NSHomeDirectory() + "/Library/Mail"
        guard FileManager.default.fileExists(atPath: base) else { return .noMail }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return .needsFullDiskAccess }
        guard let version = MailFiles.versionFolder(names) else { return .noMail }
        let root = base + "/" + version
        guard FileManager.default.isReadableFile(atPath: root + "/MailData/Envelope Index"),
              (try? withIndex(root) { _, columns in !columns.isEmpty }) == true else { return .needsFullDiskAccess }
        return .ready(root: root)
    }

    static func open(_ root: String) throws -> SQLiteReader {
        try SQLiteReader(path: indexPath(root))
    }

    /// One long-lived read connection on one serial queue. Opening the index and reading its schema
    /// cost more than the queries, and prepared statements stay cached on the connection. It opens
    /// again when Mail replaces the file (a new inode) or a different Mail folder is asked for.
    private final class Connection {
        let root: String
        let identity: FileIdentity?
        let db: SQLiteReader
        var columns: Set<String>
        var schemaVersion: Int64?
        init(root: String) throws {
            self.root = root
            identity = FileIdentity(path: MailStore.indexPath(root))
            db = try MailStore.open(root)
            columns = MailStore.schemaColumns(db)
            schemaVersion = try db.rows("PRAGMA schema_version").first?.first?.int
        }
    }
    struct FileIdentity: Equatable {
        let device: UInt64, inode: UInt64
        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = UInt64(info.st_dev); inode = UInt64(info.st_ino)
        }
    }
    private static let queue = DispatchQueue(label: "jevcast.mail.index", qos: .userInitiated)
    nonisolated(unsafe) private static var shared: Connection?
    /// Guards the `.emlx` store folder cache.
    private static let lock = NSLock()

    static func indexPath(_ root: String) -> String { root + "/MailData/Envelope Index" }

    /// Runs `body` on the index queue. `stop` returning true interrupts a running query, which then
    /// throws `CancellationError`, so a newer search does not wait for an older one.
    static func withIndex<T>(_ root: String, stop: (() -> Bool)? = nil, _ body: (SQLiteReader, Set<String>) throws -> T) throws -> T {
        try queue.sync {
            if stop?() == true { throw CancellationError() }
            if let current = shared, current.root != root || current.identity != FileIdentity(path: indexPath(root)) { shared = nil }
            let connection = try shared ?? Connection(root: root)
            shared = connection
            let schemaVersion = try connection.db.rows("PRAGMA schema_version").first?.first?.int
            if connection.schemaVersion != schemaVersion {
                connection.columns = schemaColumns(connection.db)
                connection.schemaVersion = schemaVersion
            }
            do { return try connection.db.withStop(stop) { try body(connection.db, connection.columns) } }
            catch {
                if stop?() == true { throw CancellationError() }
                shared = nil
                throw error
            }
        }
    }

    static func mailboxes(root: String) throws -> [MailMailbox] {
        try withIndex(root) { db, cols in try mailboxes(db, cols) }
    }

    private static func mailboxes(_ db: SQLiteReader, _ cols: Set<String>) throws -> [MailMailbox] {
        let columns = db.columns("mailboxes")
        let unread = columns.contains("unread_count") ? "unread_count" : "0"
        let total = columns.contains("total_count") ? "total_count" : "0"
        let boxes: [MailMailbox] = try db.rows("SELECT ROWID, url, \(unread), \(total) FROM mailboxes").compactMap { row in
            guard row.count == 4, let id = row[0].int, let url = row[1].text else { return nil }
            return MailMailbox(rowID: id, url: url, unread: Int(row[2].int ?? 0), total: Int(row[3].int ?? 0))
        }
        // A Gmail inbox holds no rows of its own: its messages sit in All Mail with an Inbox label.
        // Its unread count is read through the labels, so it matches the list.
        guard let labels = Columns(cols).labels else { return boxes }
        let c = Columns(cols)
        return try boxes.map { box in
            guard box.role == .inbox,
                  try !db.rows("SELECT 1 FROM labels WHERE \(labels.mailbox) = ? LIMIT 1", [.int(box.rowID)]).isEmpty else { return box }
            let (sql, arguments) = membershipCount(cols, [box.rowID], filter: "\(c.read) = 0", distinct: false)
            let count = Int(try db.rows(sql, arguments).first?.first?.int ?? 0)
            return MailMailbox(rowID: box.rowID, url: box.url, unread: count, total: box.total)
        }
    }

    /// Gmail keeps each message once, in All Mail, and records its other mailboxes (Inbox, Sent,
    /// its labels) in the `labels` table. The column names are read from the index itself.
    struct LabelTable: Equatable, Sendable {
        let message: String, mailbox: String
    }

    static func labelTable(_ db: SQLiteReader) -> LabelTable? {
        let names = db.columns("labels")
        guard !names.isEmpty else { return nil }
        let keys = (try? db.rows("SELECT \"table\", \"from\" FROM pragma_foreign_key_list('labels')")) ?? []
        func column(_ table: String, _ fallbacks: [String]) -> String? {
            let linked = keys.first { $0.count == 2 && $0[0].text?.lowercased() == table }?[1].text
            return ([linked].compactMap { $0 } + fallbacks).first { names.contains($0) && isIdentifier($0) }
        }
        guard let message = column("messages", ["message_id", "message"]),
              let mailbox = column("mailboxes", ["mailbox_id", "mailbox"]), message != mailbox else { return nil }
        return LabelTable(message: message, mailbox: mailbox)
    }

    static func isIdentifier(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// The `messages` columns, plus two marker entries naming the `labels` columns when the table exists.
    static func schemaColumns(_ db: SQLiteReader) -> Set<String> {
        var columns = db.columns("messages")
        if let labels = labelTable(db) { columns.insert("@labels.message:" + labels.message); columns.insert("@labels.mailbox:" + labels.mailbox) }
        return columns
    }

    /// Rows in `mailboxes`, by their own mailbox or by a label, each row once, with `filter` applied.
    /// The two parts do not overlap, so their counts add up.
    static func membershipCount(_ cols: Set<String>, _ mailboxes: [Int64], filter: String? = nil, distinct: Bool) -> (String, [SQLiteReader.Value]) {
        let c = Columns(cols)
        let list = "(" + mailboxes.map { _ in "?" }.joined(separator: ",") + ")"
        let ids: [SQLiteReader.Value] = mailboxes.map { .int($0) }
        let extra = filter.map { " AND " + $0 } ?? ""
        var parts = ["SELECT \(c.key) AS k FROM messages m WHERE \(c.deleted) = 0 AND m.mailbox IN \(list)\(extra)"]
        var arguments = ids
        if let labels = c.labels {
            parts.append("SELECT \(c.key) AS k FROM messages m WHERE \(c.deleted) = 0 AND m.ROWID IN (SELECT \(labels.message) FROM labels WHERE \(labels.mailbox) IN \(list)) AND m.mailbox NOT IN \(list)\(extra)")
            arguments += ids + ids
        }
        let what = distinct ? "COUNT(DISTINCT k)" : "COUNT(*)"
        return ("SELECT \(what) FROM (" + parts.joined(separator: " UNION ALL ") + ")", arguments)
    }

    /// The label mailboxes of each row, for rows that have any.
    static func labels(_ db: SQLiteReader, _ cols: Set<String>, rowIDs: [Int64]) throws -> [Int64: [Int64]] {
        guard let labels = Columns(cols).labels, !rowIDs.isEmpty else { return [:] }
        var result: [Int64: [Int64]] = [:]
        for start in stride(from: 0, to: rowIDs.count, by: 500) {
            let chunk = Array(rowIDs[start..<min(start + 500, rowIDs.count)])
            let sql = "SELECT \(labels.message), \(labels.mailbox) FROM labels WHERE \(labels.message) IN ("
                + chunk.map { _ in "?" }.joined(separator: ",") + ") ORDER BY 1, 2"
            for row in try db.rows(sql, chunk.map { .int($0) }) where row.count == 2 {
                guard let id = row[0].int, let box = row[1].int else { continue }
                result[id, default: []].append(box)
            }
        }
        return result
    }

    static func withLabels(_ db: SQLiteReader, _ cols: Set<String>, _ messages: [MailSummary]) throws -> [MailSummary] {
        let found = try labels(db, cols, rowIDs: messages.map(\.rowID))
        guard !found.isEmpty else { return messages }
        return messages.map { message in var copy = message; copy.labels = found[message.rowID] ?? []; return copy }
    }

    /// A place in the newest-first order: `date_received`, then `ROWID`, both descending.
    struct Cursor: Equatable, Hashable, Sendable {
        var date: Double
        var rowID: Int64
        init(date: Double, rowID: Int64) { self.date = date; self.rowID = rowID }
        init(_ message: MailSummary) { date = message.date.timeIntervalSince1970; rowID = message.rowID }
    }

    static let pageSize = 200

    struct Query: Equatable {
        var mailboxes: [Int64]
        var text = ""
        var unreadOnly = false
        var flaggedOnly = false
        var rowIDs: [Int64] = []
        var limit = MailStore.pageSize
        /// The preview text costs a lookup per row, so only a caller that shows it asks for it.
        var includePreview = false
        /// Only messages older than this: the next page.
        var before: Cursor?
        /// Only messages newer than this: a refresh above the top of the list.
        var after: Cursor?
        /// Shows one copy of an email that sits in several mailboxes, such as Gmail's All Mail and Inbox.
        var dedupe = false
        /// When copies are dropped, the copy in one of these mailboxes stays (the inbox).
        var preferred: Set<Int64> = []
        func with(limit: Int) -> Query { var copy = self; copy.limit = limit; return copy }
        func after(_ after: Cursor?, before: Cursor?) -> Query { var copy = self; copy.after = after; copy.before = before; return copy }
    }

    struct Page: Equatable {
        var messages: [MailSummary]
        /// The newest and oldest canonical rows the query read.
        var first: Cursor?
        var last: Cursor?
        /// True when the query filled its limit, so an older page may exist.
        var hasMore: Bool
    }

    /// Messages in the given mailboxes, newest first. Column names adapt to the index's version.
    static func messages(root: String, _ query: Query) throws -> [MailSummary] {
        try page(root: root, query).messages
    }

    static func page(root: String, _ query: Query, stop: (() -> Bool)? = nil) throws -> Page {
        try withIndex(root, stop: stop) { db, cols in try page(db, cols, query) }
    }

    /// Without `dedupe` one read makes the page. With it, reads go on past dropped copies until the
    /// page is full, so a stretch of archive copies never shows as an empty page.
    static func page(_ db: SQLiteReader, _ cols: Set<String>, _ query: Query) throws -> Page {
        let limit = max(1, min(query.limit, 2000))
        var batch = query
        var result = Page(messages: [], first: nil, last: nil, hasMore: false)
        for _ in 0..<20 {
            let (sql, arguments) = pageSQL(cols, batch)
            guard let sql else { return result }
            let rows = try db.rows(sql, arguments)
            let kept = query.dedupe ? try canonicalRows(db, cols, query, rows) : rows
            let messages = try withLabels(db, cols, summaries(kept))
            if result.first == nil { result.first = cursor(rows.first) }
            if result.messages.count + messages.count >= limit, rows.count >= limit || result.messages.count + messages.count > limit {
                // The page ends at its last shown row; rows after it are read again next time.
                result.messages += messages.prefix(limit - result.messages.count)
                result.last = result.messages.last.map(Cursor.init)
                result.hasMore = true
                return result
            }
            result.messages += messages
            result.last = cursor(rows.last) ?? result.last
            result.hasMore = rows.count >= limit
            guard result.hasMore, let last = result.last else { return result }
            batch.before = last
        }
        return result
    }

    private static func cursor(_ row: [SQLiteReader.Value]?) -> Cursor? {
        guard let row, row.count == 11, let id = row[0].int else { return nil }
        return Cursor(date: row[6].double ?? 0, rowID: id)
    }

    /// Mail's read, flagged, and deleted flags: separate columns in newer indexes, bits before.
    struct Columns {
        let read, flagged, deleted, key: String
        let prefix: String
        let summary: Bool
        let labels: LabelTable?
        init(_ cols: Set<String>) {
            let message = cols.first { $0.hasPrefix("@labels.message:") }?.dropFirst(16)
            let mailbox = cols.first { $0.hasPrefix("@labels.mailbox:") }?.dropFirst(16)
            labels = message.flatMap { m in mailbox.map { LabelTable(message: String(m), mailbox: String($0)) } }
            read = cols.contains("read") ? "m.read" : "(m.flags & 1)"
            flagged = cols.contains("flagged") ? "m.flagged" : "((m.flags >> 4) & 1)"
            deleted = cols.contains("deleted") ? "m.deleted" : "((m.flags >> 1) & 1)"
            prefix = cols.contains("subject_prefix") ? "COALESCE(m.subject_prefix, '') || " : ""
            summary = cols.contains("summary")
            // A copy of one email in two mailboxes shares its global ID; older indexes have a
            // Message-ID hash. A row without either is its own email.
            var keys: [String] = []
            if cols.contains("global_message_id") { keys.append("CASE WHEN m.global_message_id != 0 THEN 'global:' || m.global_message_id END") }
            if cols.contains("message_id") { keys.append("CASE WHEN m.message_id != 0 THEN 'message:' || m.message_id END") }
            key = keys.isEmpty ? "'row:' || m.ROWID" : "COALESCE(" + (keys + ["'row:' || m.ROWID"]).joined(separator: ", ") + ")"
        }
    }

    /// Most mailboxes of any account are read as one index walk each, so a page never scans the
    /// whole table. More than this many fall back to one `IN` list.
    static let maxArms = 300

    /// The rows a list reads, newest first: one arm per mailbox, each walking Mail's (mailbox, date)
    /// order and stopping at `limit`, merged. With `match`, every typed word must appear in the
    /// subject or the sender; the small subject and address tables are searched once, as
    /// materialized lists the arms probe. Returns nil when the query has no scope.
    struct Scope { var ctes: [String]; var rows: String; var arguments: [SQLiteReader.Value]; var words: [String] }
    static func scope(_ cols: Set<String>, _ query: Query, limit: Int, match: Bool) -> Scope? {
        let c = Columns(cols)
        var arguments: [SQLiteReader.Value] = []
        let searchWords = words(query.text)
        var ctes: [String] = []
        for (index, word) in searchWords.enumerated() {
            arguments.append(.text(SQLiteReader.likePattern(word)))
            let n = "?\(arguments.count)"
            ctes.append("w\(index)s AS MATERIALIZED (SELECT ROWID FROM subjects WHERE subject LIKE \(n) ESCAPE '\\')")
            ctes.append("w\(index)a AS MATERIALIZED (SELECT ROWID FROM addresses WHERE address LIKE \(n) ESCAPE '\\' OR comment LIKE \(n) ESCAPE '\\')")
        }
        func arm(_ scope: String, _ scopeArguments: [SQLiteReader.Value]) -> String {
            var sql = "SELECT m.ROWID AS id, m.date_received AS d FROM messages m WHERE \(scope) AND \(c.deleted) = 0"
            arguments += scopeArguments
            if query.unreadOnly { sql += " AND \(c.read) = 0" }
            if query.flaggedOnly { sql += " AND \(c.flagged) = 1" }
            if let before = query.before {
                sql += " AND m.date_received <= ? AND (m.date_received < ? OR m.ROWID < ?)"
                arguments += [.double(before.date), .double(before.date), .int(before.rowID)]
            }
            if let after = query.after {
                sql += " AND m.date_received >= ? AND (m.date_received > ? OR m.ROWID > ?)"
                arguments += [.double(after.date), .double(after.date), .int(after.rowID)]
            }
            if match { for index in searchWords.indices { sql += " AND (m.subject IN w\(index)s OR m.sender IN w\(index)a)" } }
            return "SELECT * FROM (" + sql + " ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(limit))"
        }
        var arms: [String] = []
        if !query.rowIDs.isEmpty {
            arms.append(arm("m.ROWID IN (" + query.rowIDs.map { _ in "?" }.joined(separator: ",") + ")", query.rowIDs.map { .int($0) }))
        } else if query.mailboxes.isEmpty {
            return nil
        } else if query.mailboxes.count > maxArms {
            arms.append(arm("m.mailbox IN (" + query.mailboxes.map { _ in "?" }.joined(separator: ",") + ")", query.mailboxes.map { .int($0) }))
        } else {
            for box in query.mailboxes { arms.append(arm("m.mailbox = ?", [.int(box)])) }
        }
        // Gmail's messages reach Inbox, Sent, and labels through the labels table. One more arm reads
        // them; UNION keeps a row once when it is also found by its own mailbox (All Mail).
        let labelled = query.rowIDs.isEmpty && c.labels != nil
        if let labels = c.labels, labelled {
            arms.append(arm("m.ROWID IN (SELECT \(labels.message) FROM labels WHERE \(labels.mailbox) IN ("
                + query.mailboxes.map { _ in "?" }.joined(separator: ",") + "))", query.mailboxes.map { .int($0) }))
        }
        let rows = arms.joined(separator: labelled ? " UNION " : " UNION ALL ") + " ORDER BY d DESC, id DESC LIMIT \(limit)"
        return Scope(ctes: ctes, rows: rows, arguments: arguments, words: searchWords)
    }

    /// The columns `makePage` reads, for rows `m` joined to their subject `s` and sender `a`.
    static func listColumns(_ cols: Set<String>, preview: Bool) -> String {
        let c = Columns(cols)
        let summary = c.summary && preview ? "COALESCE((SELECT summary FROM summaries WHERE ROWID = m.summary), '')" : "''"
        let conversation = cols.contains("conversation_id") ? "COALESCE(m.conversation_id, m.ROWID)" : "m.ROWID"
        return """
        m.ROWID, m.mailbox, \(c.prefix)COALESCE(s.subject, ''), COALESCE(a.comment, ''), COALESCE(a.address, ''),
               \(summary), m.date_received, \(c.read), \(c.flagged), \(conversation), \(c.key)
        """
    }

    /// The page query. A search matches subjects and senders here; bodies are searched in
    /// bounded steps by `bodyStep`, because Mail's summaries are too large to scan per keystroke.
    /// Details join only for the rows that make the page.
    static func pageSQL(_ cols: Set<String>, _ query: Query) -> (String?, [SQLiteReader.Value]) {
        let limit = max(1, min(query.limit, 2000))
        guard let scope = scope(cols, query, limit: limit, match: true) else { return (nil, []) }
        let with = scope.ctes.isEmpty ? "" : "WITH " + scope.ctes.joined(separator: ", ") + "\n"
        let sql = with + """
        SELECT \(listColumns(cols, preview: query.includePreview))
        FROM (\(scope.rows)) p
        JOIN messages m ON m.ROWID = p.id
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        ORDER BY p.d DESC, p.id DESC
        """
        return (sql, scope.arguments)
    }

    /// Drops rows that are not their email's chosen copy. The copy in a preferred mailbox (the
    /// inbox) wins, then the newest. The choice looks at every copy in scope, also copies on other
    /// pages, so an archive copy never shows when the inbox copy is further down. One query per
    /// key kind reads the copies of this page's emails, instead of a correlated lookup per row,
    /// which scanned the whole table per row when Mail has no index on the key.
    static func canonicalRows(_ db: SQLiteReader, _ cols: Set<String>, _ query: Query, _ rows: [[SQLiteReader.Value]]) throws -> [[SQLiteReader.Value]] {
        let c = Columns(cols)
        var globals: [Int64] = [], messageIDs: [Int64] = []
        for row in rows where row.count == 11 {
            guard let key = row[10].text else { continue }
            if key.hasPrefix("global:"), let id = Int64(key.dropFirst(7)) { globals.append(id) }
            if key.hasPrefix("message:"), let id = Int64(key.dropFirst(8)) { messageIDs.append(id) }
        }
        var eligible = "\(c.deleted) = 0"
        var scopeArguments: [SQLiteReader.Value]
        if query.rowIDs.isEmpty {
            let list = "(" + query.mailboxes.map { _ in "?" }.joined(separator: ",") + ")"
            scopeArguments = query.mailboxes.map { .int($0) }
            if let labels = c.labels {
                eligible += " AND (m.mailbox IN \(list) OR m.ROWID IN (SELECT \(labels.message) FROM labels WHERE \(labels.mailbox) IN \(list)))"
                scopeArguments += scopeArguments
            } else {
                eligible += " AND m.mailbox IN \(list)"
            }
        } else {
            eligible += " AND m.ROWID IN (" + query.rowIDs.map { _ in "?" }.joined(separator: ",") + ")"
            scopeArguments = query.rowIDs.map { .int($0) }
        }
        if query.unreadOnly { eligible += " AND \(c.read) = 0" }
        if query.flaggedOnly { eligible += " AND \(c.flagged) = 1" }
        var best: [String: (preferred: Bool, date: Double, rowID: Int64)] = [:]
        // A Gmail row counts as preferred when it carries a preferred mailbox's label (the inbox).
        let preferredList = query.preferred.sorted()
        var labelled = "0"
        if let labels = c.labels, !preferredList.isEmpty {
            labelled = "EXISTS (SELECT 1 FROM labels WHERE \(labels.message) = m.ROWID AND \(labels.mailbox) IN ("
                + preferredList.map { _ in "?" }.joined(separator: ",") + "))"
        }
        let labelArguments: [SQLiteReader.Value] = labelled == "0" ? [] : preferredList.map { .int($0) }
        func read(_ column: String, _ ids: [Int64], extra: String) throws {
            guard !ids.isEmpty else { return }
            let sql = "SELECT m.ROWID, m.mailbox, m.date_received, \(c.key), \(labelled) FROM messages m WHERE m.\(column) IN ("
                + ids.map { _ in "?" }.joined(separator: ",") + ") AND " + extra + eligible
            for row in try db.rows(sql, labelArguments + ids.map { .int($0) } + scopeArguments) where row.count == 5 {
                guard let id = row[0].int, let key = row[3].text else { continue }
                let preferred = query.preferred.contains(row[1].int ?? 0) || (row[4].int ?? 0) != 0
                let candidate = (preferred: preferred, date: row[2].double ?? 0, rowID: id)
                if let old = best[key], beats(old, candidate) { continue }
                best[key] = candidate
            }
        }
        try read("global_message_id", Array(Set(globals)), extra: "")
        try read("message_id", Array(Set(messageIDs)), extra: cols.contains("global_message_id") ? "COALESCE(m.global_message_id, 0) = 0 AND " : "")
        return rows.filter { row in
            guard row.count == 11, let id = row[0].int, let key = row[10].text, let chosen = best[key] else { return true }
            return chosen.rowID == id
        }
    }

    /// True when copy `a` wins over copy `b`: preferred first, then newer.
    static func beats(_ a: (preferred: Bool, date: Double, rowID: Int64), _ b: (preferred: Bool, date: Double, rowID: Int64)) -> Bool {
        if a.preferred != b.preferred { return a.preferred }
        return a.date > b.date || (a.date == b.date && a.rowID > b.rowID)
    }

    static func words(_ text: String) -> [String] {
        Array(text.split(whereSeparator: \.isWhitespace).map(String.init).prefix(6))
    }

    static func summaries(_ rows: [[SQLiteReader.Value]]) -> [MailSummary] {
        var messages: [MailSummary] = []
        for row in rows {
            guard row.count == 11, let id = row[0].int else { continue }
            let message = MailSummary(rowID: id, mailbox: row[1].int ?? 0, subject: row[2].text ?? "", senderName: row[3].text ?? "",
                                      senderAddress: row[4].text ?? "", snippet: row[5].text ?? "",
                                      date: Date(timeIntervalSince1970: row[6].double ?? 0),
                                      read: (row[7].int ?? 0) != 0, flagged: (row[8].int ?? 0) != 0,
                                      conversation: row[9].int ?? id, messageKey: row[10].text ?? "row:\(id)")
            messages.append(message)
        }
        return messages
    }

    /// The current mailbox and flags of rows already on screen, for a refresh that does not
    /// read the whole list again. Rows Mail removed are missing from the result.
    struct RowState: Equatable {
        let mailbox: Int64; let read: Bool; let flagged: Bool
        /// Gmail's label mailboxes for the row, such as its Inbox.
        var labels: [Int64] = []
    }
    static func states(root: String, rowIDs: [Int64], stop: (() -> Bool)? = nil) throws -> [Int64: RowState] {
        guard !rowIDs.isEmpty else { return [:] }
        return try withIndex(root, stop: stop) { db, cols in
            let c = Columns(cols)
            var result: [Int64: RowState] = [:]
            // Fixed-size chunks keep one cached statement for every chunk but the last.
            for start in stride(from: 0, to: rowIDs.count, by: 500) {
                let chunk = Array(rowIDs[start..<min(start + 500, rowIDs.count)])
                let sql = "SELECT m.ROWID, m.mailbox, \(c.read), \(c.flagged) FROM messages m WHERE \(c.deleted) = 0 AND m.ROWID IN ("
                    + chunk.map { _ in "?" }.joined(separator: ",") + ")"
                for row in try db.rows(sql, chunk.map { .int($0) }) where row.count == 4 {
                    guard let id = row[0].int else { continue }
                    result[id] = RowState(mailbox: row[1].int ?? 0, read: (row[2].int ?? 0) != 0, flagged: (row[3].int ?? 0) != 0)
                }
            }
            for (id, boxes) in try labels(db, cols, rowIDs: rowIDs) where result[id] != nil { result[id]?.labels = boxes }
            return result
        }
    }

    /// How many messages the mailboxes hold, counting one copy per email when `distinct`.
    static func count(root: String, mailboxes: [Int64], distinct: Bool = false) throws -> Int {
        guard !mailboxes.isEmpty else { return 0 }
        return try withIndex(root) { db, cols in
            let (sql, arguments) = membershipCount(cols, mailboxes, distinct: distinct)
            return Int(try db.rows(sql, arguments).first?.first?.int ?? 0)
        }
    }

    /// True when Mail's index has an index that starts with (mailbox, date_received), which the
    /// page query walks. Without it each mailbox is sorted in full.
    static func hasMailboxDateIndex(root: String) -> Bool {
        (try? withIndex(root) { db, _ in
            try db.rows("SELECT name FROM pragma_index_list('messages')").contains { row in
                guard let name = row.first?.text else { return false }
                let columns = try db.rows("SELECT name FROM pragma_index_info(?) ORDER BY seqno", [.text(name)]).compactMap { $0.first?.text }
                return columns.prefix(2) == ["mailbox", "date_received"]
            }
        }) ?? false
    }

    /// A number that changes whenever Mail adds, removes, or marks messages, for cheap polling.
    static func fingerprint(root: String) -> String {
        let path = indexPath(root)
        let attributes = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)) ?? [:] }
        let main = attributes(path), wal = attributes(path + "-wal")
        return "\(FileIdentity(path: path)?.inode ?? 0)-\((main[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((wal[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(wal[.size] as? Int ?? 0)"
    }

    /// The message's `.emlx` file, or nil when Mail has not downloaded it.
    /// The store folders inside each mailbox folder, read once.
    nonisolated(unsafe) private static var storeCache: [String: [String]] = [:]

    static func messageFile(root: String, mailbox: MailMailbox, rowID: Int64) -> String? {
        let folder = mailbox.folder(in: root)
        let relative = MailFiles.relativePaths(rowID: rowID)
        let stores: [String] = lock.withLock {
            if let cached = storeCache[folder] { return cached }
            let found = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasSuffix(".mbox") && !$0.hasSuffix(".plist") }
            storeCache[folder] = found
            return found
        }
        for store in [""] + stores.map({ $0 + "/" }) {
            for path in relative {
                let candidate = folder + "/" + store + path
                if FileManager.default.fileExists(atPath: candidate) { return candidate }
            }
        }
        // Some layouts differ. Search this mailbox's folder, at most a few levels down.
        let names = Set(relative.map { ($0 as NSString).lastPathComponent })
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else { return nil }
        var visited = 0
        while let item = enumerator.nextObject() as? String {
            // A huge mailbox is not walked in full for one missing file.
            visited += 1
            if visited > 20_000 { return nil }
            if enumerator.level > 7 { enumerator.skipDescendants(); continue }
            if item.hasSuffix(".mbox") { enumerator.skipDescendants(); continue }
            if names.contains((item as NSString).lastPathComponent) { return folder + "/" + item }
        }
        return nil
    }

    static func message(root: String, mailbox: MailMailbox, rowID: Int64) -> MIMEMessage? {
        guard let path = messageFile(root: root, mailbox: mailbox, rowID: rowID),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return MIMEMessage.parseEMLX(data)
    }
}
