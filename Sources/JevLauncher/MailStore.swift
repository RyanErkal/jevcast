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
              (try? open(root))?.columns("messages").isEmpty == false else { return .needsFullDiskAccess }
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
        let columns: Set<String>
        init(root: String) throws {
            self.root = root
            identity = FileIdentity(path: MailStore.indexPath(root))
            db = try MailStore.open(root)
            columns = db.columns("messages")
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
            do { return try connection.db.withStop(stop) { try body(connection.db, connection.columns) } }
            catch {
                if stop?() == true { throw CancellationError() }
                shared = nil
                throw error
            }
        }
    }

    static func mailboxes(root: String) throws -> [MailMailbox] {
        try withIndex(root) { db, _ in try mailboxes(db) }
    }

    private static func mailboxes(_ db: SQLiteReader) throws -> [MailMailbox] {
        let columns = db.columns("mailboxes")
        let unread = columns.contains("unread_count") ? "unread_count" : "0"
        let total = columns.contains("total_count") ? "total_count" : "0"
        return try db.rows("SELECT ROWID, url, \(unread), \(total) FROM mailboxes").compactMap { row in
            guard row.count == 4, let id = row[0].int, let url = row[1].text else { return nil }
            return MailMailbox(rowID: id, url: url, unread: Int(row[2].int ?? 0), total: Int(row[3].int ?? 0))
        }
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
        /// The newest and oldest rows the query read, before copies were dropped.
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
        try withIndex(root, stop: stop) { db, cols in
            let (sql, arguments) = pageSQL(cols, query)
            guard let sql else { return Page(messages: [], first: nil, last: nil, hasMore: false) }
            return makePage(try db.rows(sql, arguments), query)
        }
    }

    /// Mail's read, flagged, and deleted flags: separate columns in newer indexes, bits before.
    struct Columns {
        let read, flagged, deleted, key: String
        let prefix: String
        let summary: Bool
        init(_ cols: Set<String>) {
            read = cols.contains("read") ? "m.read" : "(m.flags & 1)"
            flagged = cols.contains("flagged") ? "m.flagged" : "((m.flags >> 4) & 1)"
            deleted = cols.contains("deleted") ? "m.deleted" : "((m.flags >> 1) & 1)"
            prefix = cols.contains("subject_prefix") ? "COALESCE(m.subject_prefix, '') || " : ""
            summary = cols.contains("summary")
            // A copy of one email in two mailboxes shares its global ID; older indexes have a
            // Message-ID hash. A row without either is its own email.
            var keys: [String] = []
            if cols.contains("global_message_id") { keys.append("NULLIF(m.global_message_id, 0)") }
            if cols.contains("message_id") { keys.append("NULLIF(m.message_id, 0)") }
            key = keys.isEmpty ? "-m.ROWID" : "COALESCE(" + (keys + ["-m.ROWID"]).joined(separator: ", ") + ")"
        }
    }

    /// Most mailboxes of any account are read as one index walk each, so a page never scans the
    /// whole table. More than this many fall back to one `IN` list.
    static let maxArms = 300

    /// The page query: one arm per mailbox, each walking Mail's (mailbox, date) order and stopping
    /// at the page size, merged newest first. Details join only for the rows that make the page.
    static func pageSQL(_ cols: Set<String>, _ query: Query) -> (String?, [SQLiteReader.Value]) {
        let c = Columns(cols)
        let limit = max(1, min(query.limit, 2000))
        var arguments: [SQLiteReader.Value] = []
        // Each small table is searched once per query, as a materialized list shared by every
        // mailbox arm; the arms then only probe the IDs found.
        let searchWords = words(query.text)
        var ctes: [String] = []
        for (index, word) in searchWords.enumerated() {
            arguments.append(.text(SQLiteReader.likePattern(word)))
            let n = "?\(arguments.count)"
            ctes.append("w\(index)s AS MATERIALIZED (SELECT ROWID FROM subjects WHERE subject LIKE \(n) ESCAPE '\\')")
            ctes.append("w\(index)a AS MATERIALIZED (SELECT ROWID FROM addresses WHERE address LIKE \(n) ESCAPE '\\' OR comment LIKE \(n) ESCAPE '\\')")
            if c.summary { ctes.append("w\(index)b AS MATERIALIZED (SELECT ROWID FROM summaries WHERE summary LIKE \(n) ESCAPE '\\')") }
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
            for index in searchWords.indices {
                // Every word must appear in the subject, the sender, or the text Mail keeps for the body.
                var match = "m.subject IN w\(index)s OR m.sender IN w\(index)a"
                if c.summary { match += " OR m.summary IN w\(index)b" }
                sql += " AND (" + match + ")"
            }
            return "SELECT * FROM (" + sql + " ORDER BY m.date_received DESC, m.ROWID DESC LIMIT \(limit))"
        }
        var arms: [String] = []
        if !query.rowIDs.isEmpty {
            arms.append(arm("m.ROWID IN (" + query.rowIDs.map { _ in "?" }.joined(separator: ",") + ")", query.rowIDs.map { .int($0) }))
        } else if query.mailboxes.isEmpty {
            guard query.flaggedOnly || query.unreadOnly else { return (nil, []) }
            arms.append(arm("1", []))
        } else if query.mailboxes.count > maxArms {
            arms.append(arm("m.mailbox IN (" + query.mailboxes.map { _ in "?" }.joined(separator: ",") + ")", query.mailboxes.map { .int($0) }))
        } else {
            for box in query.mailboxes { arms.append(arm("m.mailbox = ?", [.int(box)])) }
        }
        let summary = c.summary && query.includePreview ? "COALESCE((SELECT summary FROM summaries WHERE ROWID = m.summary), '')" : "''"
        let conversation = cols.contains("conversation_id") ? "COALESCE(m.conversation_id, m.ROWID)" : "m.ROWID"
        let with = ctes.isEmpty ? "" : "WITH " + ctes.joined(separator: ", ") + "\n"
        let sql = with + """
        SELECT m.ROWID, m.mailbox, \(c.prefix)COALESCE(s.subject, ''), COALESCE(a.comment, ''), COALESCE(a.address, ''),
               \(summary), m.date_received, \(c.read), \(c.flagged), \(conversation), \(c.key)
        FROM (\(arms.joined(separator: " UNION ALL ")) ORDER BY d DESC, id DESC LIMIT \(limit)) p
        JOIN messages m ON m.ROWID = p.id
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        ORDER BY p.d DESC, p.id DESC
        """
        return (sql, arguments)
    }

    static func words(_ text: String) -> [String] {
        Array(text.split(whereSeparator: \.isWhitespace).map(String.init).prefix(6))
    }

    private static func makePage(_ rows: [[SQLiteReader.Value]], _ query: Query) -> Page {
        var messages: [MailSummary] = []
        var slot: [Int64: Int] = [:]
        var first: Cursor?, last: Cursor?
        for row in rows {
            guard row.count == 11, let id = row[0].int else { continue }
            let message = MailSummary(rowID: id, mailbox: row[1].int ?? 0, subject: row[2].text ?? "", senderName: row[3].text ?? "",
                                      senderAddress: row[4].text ?? "", snippet: row[5].text ?? "",
                                      date: Date(timeIntervalSince1970: row[6].double ?? 0),
                                      read: (row[7].int ?? 0) != 0, flagged: (row[8].int ?? 0) != 0,
                                      conversation: row[9].int ?? id, messageKey: row[10].int ?? -id)
            let cursor = Cursor(date: row[6].double ?? 0, rowID: id)
            if first == nil { first = cursor }
            last = cursor
            guard query.dedupe else { messages.append(message); continue }
            if let index = slot[message.messageKey] {
                // The inbox copy wins, so actions work on the mailbox you know.
                if query.preferred.contains(message.mailbox), !query.preferred.contains(messages[index].mailbox) { messages[index] = message }
                continue
            }
            slot[message.messageKey] = messages.count
            messages.append(message)
        }
        return Page(messages: messages, first: first, last: last, hasMore: rows.count >= max(1, min(query.limit, 2000)))
    }

    /// The current mailbox and flags of rows already on screen, for a refresh that does not
    /// read the whole list again. Rows Mail removed are missing from the result.
    struct RowState: Equatable { let mailbox: Int64; let read: Bool; let flagged: Bool }
    static func states(root: String, rowIDs: [Int64]) throws -> [Int64: RowState] {
        guard !rowIDs.isEmpty else { return [:] }
        return try withIndex(root) { db, cols in
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
            return result
        }
    }

    /// How many messages the mailboxes hold, counting one copy per email when `distinct`.
    static func count(root: String, mailboxes: [Int64], distinct: Bool = false) throws -> Int {
        guard !mailboxes.isEmpty else { return 0 }
        return try withIndex(root) { db, cols in
            let c = Columns(cols)
            let what = distinct ? "COUNT(DISTINCT \(c.key))" : "COUNT(*)"
            let sql = "SELECT \(what) FROM messages m WHERE \(c.deleted) = 0 AND m.mailbox IN (" + mailboxes.map { _ in "?" }.joined(separator: ",") + ")"
            return Int(try db.rows(sql, mailboxes.map { .int($0) }).first?.first?.int ?? 0)
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
        return "\((main[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((wal[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(wal[.size] as? Int ?? 0)"
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
