import Foundation
import SQLite3

/// A synthetic `Envelope Index` shaped like Apple Mail's: the same tables, the columns the
/// queries read, and a (mailbox, date_received) index. Nothing in it is real mail.
enum MailFixture {
    struct Layout {
        var gmailInbox = 30_000
        /// Each Gmail inbox message also has a copy in All Mail, as Gmail does.
        var allMailOnly = 10_000
        var sent = 10_000
        var trash = 5_000
        var exchangeInbox = 10_000
        var projects = 5_000
        var total: Int { gmailInbox * 2 + allMailOnly + sent + trash + exchangeInbox + projects }
    }

    static let mailboxes: [(Int64, String)] = [
        (1, "imap://GMAIL-1/INBOX"), (2, "imap://GMAIL-1/%5BGmail%5D/All%20Mail"), (3, "imap://GMAIL-1/%5BGmail%5D/Sent%20Mail"),
        (4, "imap://GMAIL-1/%5BGmail%5D/Trash"), (5, "ews://EXCH-2/Inbox"), (6, "ews://EXCH-2/Projects")
    ]

    /// Builds the index under `root/MailData` and returns the root.
    @discardableResult
    static func build(root: String, layout: Layout = Layout()) throws -> String {
        try FileManager.default.createDirectory(atPath: root + "/MailData", withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(root + "/MailData/Envelope Index", &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
        exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT UNIQUE, total_count INTEGER, unread_count INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER, global_message_id INTEGER,
            remote_id INTEGER, sender INTEGER, subject_prefix TEXT, subject INTEGER, summary INTEGER, date_sent INTEGER,
            date_received INTEGER, mailbox INTEGER, flags INTEGER, read INTEGER, flagged INTEGER, deleted INTEGER,
            size INTEGER, conversation_id INTEGER, searchable_message INTEGER);
        CREATE INDEX messages_mailbox_date_received_index ON messages(mailbox, date_received);
        CREATE INDEX messages_global_message_id_index ON messages(global_message_id);
        BEGIN;
        """)
        for (id, url) in mailboxes { exec("INSERT INTO mailboxes VALUES (\(id), '\(url)', 0, 0)") }
        let words = ["invoice", "lunch", "project", "update", "meeting", "report", "travel", "offer", "receipt", "welcome"]
        for i in 1...5_000 { exec("INSERT INTO subjects VALUES (\(i), '\(words[i % 10]) \(words[(i / 10) % 10]) number \(i)')") }
        for i in 1...2_000 { exec("INSERT INTO addresses VALUES (\(i), 'person\(i)@example.com', 'Person \(i)')") }
        var insertSummary: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO summaries VALUES (?, ?)", -1, &insertSummary, nil)
        for i in 1...20_000 {
            let text = "Hello, this is body text about the \(words[(i * 7) % 10]) and the \(words[(i * 3) % 10]), reference code body\(i)."
            sqlite3_bind_int64(insertSummary, 1, Int64(i)); sqlite3_bind_text(insertSummary, 2, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(insertSummary); sqlite3_reset(insertSummary)
        }
        sqlite3_finalize(insertSummary)
        var insert: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO messages (message_id, global_message_id, sender, subject, summary, date_received, mailbox, read, flagged, deleted, conversation_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """, -1, &insert, nil)
        var global: Int64 = 1_000_000
        let start: Int64 = 1_700_000_000
        func add(_ mailbox: Int64, _ n: Int, copyTo copy: Int64? = nil) {
            for i in 0..<n {
                global += 1
                // Dates repeat every few rows, so the ROWID tie-break matters.
                let date = start + Int64(i / 3) * 60 + mailbox
                for box in [mailbox] + (copy.map { [$0] } ?? []) {
                    let values: [Int64] = [global * 31, global, Int64(i % 2_000 + 1), Int64(i % 5_000 + 1), Int64(i % 20_000 + 1), date, box,
                                           i % 5 == 0 ? 0 : 1, i % 50 == 0 ? 1 : 0, global]
                    for (index, value) in values.enumerated() { sqlite3_bind_int64(insert, Int32(index + 1), value) }
                    sqlite3_step(insert); sqlite3_reset(insert)
                }
            }
        }
        add(1, layout.gmailInbox, copyTo: 2)
        add(2, layout.allMailOnly)
        add(3, layout.sent)
        add(4, layout.trash)
        add(5, layout.exchangeInbox)
        add(6, layout.projects)
        sqlite3_finalize(insert)
        exec("COMMIT; PRAGMA wal_checkpoint(TRUNCATE);")
        return root
    }
}
