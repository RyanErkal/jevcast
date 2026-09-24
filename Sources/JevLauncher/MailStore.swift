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
        try SQLiteReader(path: root + "/MailData/Envelope Index")
    }

    /// One read connection, kept open and used by one caller at a time. Opening the index and
    /// reading its schema for every refresh cost more than the queries themselves.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: (root: String, db: SQLiteReader, columns: Set<String>)?

    static func withIndex<T>(_ root: String, _ body: (SQLiteReader, Set<String>) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if shared?.root != root {
            let db = try open(root)
            shared = (root, db, db.columns("messages"))
        }
        do { return try body(shared!.db, shared!.columns) }
        catch { shared = nil; throw error }
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

    struct Query: Equatable {
        var mailboxes: [Int64]
        var text = ""
        var unreadOnly = false
        var flaggedOnly = false
        var rowIDs: [Int64] = []
        var limit = 300
        /// The preview text costs a lookup per row, so only a caller that shows it asks for it.
        var includePreview = false
    }

    /// Messages in the given mailboxes, newest first. Column names adapt to the index's version.
    static func messages(root: String, _ query: Query) throws -> [MailSummary] {
        try withIndex(root) { db, cols in try messages(db, cols, query) }
    }

    private static func messages(_ db: SQLiteReader, _ cols: Set<String>, _ query: Query) throws -> [MailSummary] {
        guard !query.mailboxes.isEmpty || query.flaggedOnly || query.unreadOnly || !query.rowIDs.isEmpty else { return [] }
        let read = cols.contains("read") ? "m.read" : "(m.flags & 1)"
        let flagged = cols.contains("flagged") ? "m.flagged" : "((m.flags >> 4) & 1)"
        let deleted = cols.contains("deleted") ? "m.deleted" : "((m.flags >> 1) & 1)"
        let prefix = cols.contains("subject_prefix") ? "COALESCE(m.subject_prefix, '') || " : ""
        let summary = cols.contains("summary") && query.includePreview ? "COALESCE((SELECT summary FROM summaries WHERE ROWID = m.summary), '')" : "''"
        let conversation = cols.contains("conversation_id") ? "COALESCE(m.conversation_id, m.ROWID)" : "m.ROWID"
        var sql = """
        SELECT m.ROWID, m.mailbox, \(prefix)COALESCE(s.subject, ''), COALESCE(a.comment, ''), COALESCE(a.address, ''),
               \(summary), m.date_received, \(read), \(flagged), \(conversation)
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        WHERE \(deleted) = 0
        """
        var arguments: [SQLiteReader.Value] = []
        if !query.mailboxes.isEmpty {
            sql += " AND m.mailbox IN (" + Array(repeating: "?", count: query.mailboxes.count).joined(separator: ",") + ")"
            arguments += query.mailboxes.map { .int($0) }
        }
        if !query.rowIDs.isEmpty {
            sql += " AND m.ROWID IN (" + Array(repeating: "?", count: query.rowIDs.count).joined(separator: ",") + ")"
            arguments += query.rowIDs.map { .int($0) }
        }
        if query.unreadOnly { sql += " AND \(read) = 0" }
        if query.flaggedOnly { sql += " AND \(flagged) = 1" }
        let words = query.text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        for word in words.prefix(6) {
            // Every word must appear in the subject or the sender.
            sql += " AND (s.subject LIKE ? ESCAPE '\\' OR a.address LIKE ? ESCAPE '\\' OR a.comment LIKE ? ESCAPE '\\')"
            let pattern = SQLiteReader.Value.text(SQLiteReader.likePattern(word))
            arguments += [pattern, pattern, pattern]
        }
        sql += " ORDER BY m.date_received DESC LIMIT \(max(1, min(query.limit, 2000)))"
        return try db.rows(sql, arguments).compactMap { row in
            guard row.count == 10, let id = row[0].int else { return nil }
            return MailSummary(rowID: id, mailbox: row[1].int ?? 0, subject: row[2].text ?? "", senderName: row[3].text ?? "",
                               senderAddress: row[4].text ?? "", snippet: row[5].text ?? "",
                               date: Date(timeIntervalSince1970: row[6].double ?? 0),
                               read: (row[7].int ?? 0) != 0, flagged: (row[8].int ?? 0) != 0, conversation: row[9].int ?? id)
        }
    }

    /// A number that changes whenever Mail adds, removes, or marks messages, for cheap polling.
    static func fingerprint(root: String) -> String {
        let path = root + "/MailData/Envelope Index"
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
