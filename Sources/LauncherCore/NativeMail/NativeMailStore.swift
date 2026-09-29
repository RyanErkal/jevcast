import Foundation

/// Jevcast's own mail store for accounts it syncs itself. The database has the tables and columns
/// of Apple Mail's `Envelope Index` that the mail window reads, and bodies sit where Mail keeps
/// them (`<account>/<mailbox>.mbox/Data/…/<row>.emlx`). So one reader, one list query, and one
/// search serve both. Extra columns hold what sync needs. Folders are 0700 and files 0600.
public actor NativeMailStore {
    public nonisolated let root: URL
    let db: MailDatabase
    /// Goes up with every change a list could show, so sync can tell whether a pass changed anything.
    public private(set) var revision = 0
    func touched() { revision += 1 }

    public nonisolated static func indexPath(root: URL) -> String { root.appendingPathComponent("MailData/Envelope Index").path }

    public init(root: URL) throws {
        self.root = root
        try Self.makeFolder(root)
        try Self.makeFolder(root.appendingPathComponent("MailData"))
        let path = Self.indexPath(root: root)
        let isNew = !FileManager.default.fileExists(atPath: path)
        db = try MailDatabase(path: path)
        if isNew { chmod(path, 0o600) }
        try Self.migrate(db)
    }

    static func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The schema. Table and column names follow Apple Mail's index where the reader uses them.
    static func migrate(_ db: MailDatabase) throws {
        try db.exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA foreign_keys=OFF;
        CREATE TABLE IF NOT EXISTS mailboxes (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT UNIQUE NOT NULL,
            total_count INTEGER NOT NULL DEFAULT 0,
            unread_count INTEGER NOT NULL DEFAULT 0,
            account TEXT NOT NULL,
            name TEXT NOT NULL,
            delimiter TEXT,
            role TEXT,
            uid_validity INTEGER,
            uid_next INTEGER,
            highest_modseq INTEGER,
            complete INTEGER NOT NULL DEFAULT 0,
            last_full_check REAL);
        CREATE TABLE IF NOT EXISTS subjects (ROWID INTEGER PRIMARY KEY, subject TEXT NOT NULL UNIQUE);
        CREATE TABLE IF NOT EXISTS addresses (ROWID INTEGER PRIMARY KEY, address TEXT NOT NULL, comment TEXT NOT NULL, UNIQUE(address, comment));
        CREATE TABLE IF NOT EXISTS summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        CREATE TABLE IF NOT EXISTS messages (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id INTEGER NOT NULL DEFAULT 0,
            global_message_id INTEGER NOT NULL DEFAULT 0,
            sender INTEGER,
            subject_prefix TEXT,
            subject INTEGER,
            summary INTEGER,
            date_received INTEGER NOT NULL,
            mailbox INTEGER NOT NULL,
            read INTEGER NOT NULL DEFAULT 0,
            flagged INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0,
            size INTEGER,
            conversation_id INTEGER,
            remote_uid INTEGER NOT NULL,
            answered INTEGER NOT NULL DEFAULT 0,
            header_message_id TEXT,
            has_body INTEGER NOT NULL DEFAULT 0,
            bulk INTEGER NOT NULL DEFAULT 0,
            pending_hide INTEGER NOT NULL DEFAULT 0,
            priority INTEGER);
        CREATE UNIQUE INDEX IF NOT EXISTS messages_mailbox_uid ON messages(mailbox, remote_uid);
        CREATE INDEX IF NOT EXISTS messages_mailbox_date_received_index ON messages(mailbox, date_received);
        CREATE INDEX IF NOT EXISTS messages_global_message_id_index ON messages(global_message_id);
        CREATE INDEX IF NOT EXISTS messages_message_id_index ON messages(message_id);
        CREATE TRIGGER IF NOT EXISTS messages_summary_cleanup AFTER DELETE ON messages
            BEGIN DELETE FROM summaries WHERE ROWID = old.summary; END;
        PRAGMA user_version=1;
        """)
    }

    // MARK: Mailboxes

    /// A mailbox and what sync knows about it.
    public struct Mailbox: Sendable, Equatable {
        public let rowID: Int64
        public let account: String
        /// The server's name, decoded, as commands use it.
        public let name: String
        public let delimiter: String?
        public let role: MailMailbox.Role?
        public let url: String
        public var uidValidity: UInt32?
        public var uidNext: UInt32?
        public var highestModSeq: UInt64?
        /// True once every older message has been read.
        public var complete: Bool
        public var lastFullCheck: Date?
    }

    /// Records the server's mailboxes for `account` and removes the ones it no longer has, with
    /// their messages. Returns the account's mailboxes, inbox first.
    @discardableResult
    public func replaceMailboxes(account: String, with entries: [IMAPListEntry]) throws -> [Mailbox] {
        let chosen = Self.syncedEntries(entries)
        try db.transaction {
            var urls: [String] = []
            for entry in chosen {
                let url = Self.url(account: account, name: entry.name, delimiter: entry.delimiter)
                urls.append(url)
                try db.run("""
                    INSERT INTO mailboxes (url, account, name, delimiter, role) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET name = excluded.name, delimiter = excluded.delimiter, role = excluded.role
                    """, [.text(url), .text(account), .text(entry.name), entry.delimiter.map { .text($0) } ?? .null,
                          Self.role(of: entry).map { .text($0.rawValue) } ?? .null])
            }
            let gone = try db.rows("SELECT ROWID, url FROM mailboxes WHERE account = ?", [.text(account)])
                .filter { !urls.contains($0[1].text ?? "") }.compactMap { $0[0].int }
            for id in gone { try removeMailbox(id) }
        }
        touched()
        return try mailboxes(account: account)
    }

    /// Mailboxes worth syncing. Virtual views that repeat other mailboxes are left out: Starred and
    /// Important, and All Mail when the account also has an Archive.
    static func syncedEntries(_ entries: [IMAPListEntry]) -> [IMAPListEntry] {
        let selectable = entries.filter(\.selectable)
        let hasArchive = selectable.contains { $0.has("\\Archive") }
        return selectable.filter { entry in
            if entry.has("\\Flagged") || entry.has("\\Important") { return false }
            if entry.has("\\All") && hasArchive { return false }
            return true
        }
    }

    static func role(of entry: IMAPListEntry) -> MailMailbox.Role? {
        if entry.name.caseInsensitiveCompare("INBOX") == .orderedSame || entry.has("\\Inbox") { return .inbox }
        if entry.has("\\Sent") { return .sent }
        if entry.has("\\Drafts") { return .drafts }
        if entry.has("\\Trash") { return .trash }
        if entry.has("\\Junk") { return .junk }
        if entry.has("\\Archive") || entry.has("\\All") { return .archive }
        return nil
    }

    /// `imap://<account>/<part>/<part>`, each part percent-encoded, the server's delimiter as "/".
    public nonisolated static func url(account: String, name: String, delimiter: String?) -> String {
        let parts = delimiter.flatMap { $0.isEmpty ? nil : name.components(separatedBy: $0) } ?? [name]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return "imap://\(account)/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
    }

    public func mailboxes(account: String) throws -> [Mailbox] {
        try db.rows("""
            SELECT ROWID, account, name, delimiter, role, uid_validity, uid_next, highest_modseq, complete, last_full_check, url
            FROM mailboxes WHERE account = ? ORDER BY CASE role WHEN 'inbox' THEN 0 WHEN 'sent' THEN 1 WHEN 'archive' THEN 2
            WHEN 'drafts' THEN 3 WHEN 'trash' THEN 5 WHEN 'junk' THEN 6 ELSE 4 END, name
            """, [.text(account)]).compactMap(Self.mailbox)
    }

    public func mailbox(_ rowID: Int64) throws -> Mailbox? {
        try db.rows("""
            SELECT ROWID, account, name, delimiter, role, uid_validity, uid_next, highest_modseq, complete, last_full_check, url
            FROM mailboxes WHERE ROWID = ?
            """, [.int(rowID)]).first.flatMap(Self.mailbox)
    }

    static func mailbox(_ row: [MailDatabase.Value]) -> Mailbox? {
        guard row.count == 11, let id = row[0].int, let account = row[1].text, let name = row[2].text, let url = row[10].text else { return nil }
        return Mailbox(rowID: id, account: account, name: name, delimiter: row[3].text, role: row[4].text.flatMap(MailMailbox.Role.init(rawValue:)), url: url,
                       uidValidity: row[5].int.flatMap(UInt32.init(exactly:)), uidNext: row[6].int.flatMap(UInt32.init(exactly:)),
                       highestModSeq: row[7].int.map { UInt64(bitPattern: $0) }, complete: (row[8].int ?? 0) != 0,
                       lastFullCheck: row[9].double.map(Date.init(timeIntervalSince1970:)))
    }

    /// Saves what the last sync learned about a mailbox.
    public func saveSyncState(_ mailbox: Mailbox) throws {
        try db.run("""
            UPDATE mailboxes SET uid_validity = ?, uid_next = ?, highest_modseq = ?, complete = ?, last_full_check = ? WHERE ROWID = ?
            """, [mailbox.uidValidity.map { .int(Int64($0)) } ?? .null, mailbox.uidNext.map { .int(Int64($0)) } ?? .null,
                  mailbox.highestModSeq.map { .int(Int64(bitPattern: $0)) } ?? .null, .int(mailbox.complete ? 1 : 0),
                  mailbox.lastFullCheck.map { .double($0.timeIntervalSince1970) } ?? .null, .int(mailbox.rowID)])
    }

    /// The server renumbered the mailbox: every local copy is dropped, and sync reads it again.
    public func reset(_ mailbox: Mailbox, uidValidity: UInt32) throws -> Mailbox {
        try db.run("DELETE FROM messages WHERE mailbox = ?", [.int(mailbox.rowID)])
        removeBodies(mailboxRowID: mailbox.rowID, url: mailbox.url)
        touched()
        var fresh = mailbox
        fresh.uidValidity = uidValidity; fresh.uidNext = nil; fresh.highestModSeq = nil; fresh.complete = false; fresh.lastFullCheck = nil
        try saveSyncState(fresh)
        try refreshCounts(mailbox.rowID)
        return fresh
    }

    private func removeMailbox(_ id: Int64) throws {
        if let url = try db.rows("SELECT url FROM mailboxes WHERE ROWID = ?", [.int(id)]).first?.first?.text {
            removeBodies(mailboxRowID: id, url: url)
        }
        try db.run("DELETE FROM messages WHERE mailbox = ?", [.int(id)])
        try db.run("DELETE FROM mailboxes WHERE ROWID = ?", [.int(id)])
    }

    /// Removes an account's mailboxes, messages, and files from this Mac. The server is not touched.
    public func removeAccount(_ account: String) throws {
        try db.transaction {
            for row in try db.rows("SELECT ROWID FROM mailboxes WHERE account = ?", [.text(account)]) {
                if let id = row.first?.int { try db.run("DELETE FROM messages WHERE mailbox = ?", [.int(id)]) }
            }
            try db.run("DELETE FROM mailboxes WHERE account = ?", [.text(account)])
        }
        touched()
        guard Self.isSafeName(account) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(account, isDirectory: true))
    }

    /// Account IDs are UUIDs; anything else is never used as a folder name.
    nonisolated static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Bodies sit in the mailbox folder's `Data` folder. Child mailboxes' folders sit beside it and stay.
    nonisolated func bodyFolder(mailboxRowID: Int64, url: String) -> URL {
        URL(fileURLWithPath: MailMailbox(rowID: mailboxRowID, url: url, unread: 0, total: 0).folder(in: root.path), isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    func removeBodies(mailboxRowID: Int64, url: String) {
        try? FileManager.default.removeItem(at: bodyFolder(mailboxRowID: mailboxRowID, url: url))
    }

    /// Recounts a mailbox's messages and unread messages for the mailbox list.
    public func refreshCounts(_ mailbox: Int64) throws {
        try db.run("""
            UPDATE mailboxes SET
                total_count = (SELECT COUNT(*) FROM messages WHERE mailbox = ?1 AND deleted = 0),
                unread_count = (SELECT COUNT(*) FROM messages WHERE mailbox = ?1 AND deleted = 0 AND read = 0)
            WHERE ROWID = ?1
            """, [.int(mailbox)])
    }
}
