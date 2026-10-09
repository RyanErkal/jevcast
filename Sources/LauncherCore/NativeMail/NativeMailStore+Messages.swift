import Foundation

extension NativeMailStore {
    /// What the store holds for a mailbox: its row count and UID range.
    public struct Extent: Sendable, Equatable {
        public var count: Int
        public var minUID: UInt32?
        public var maxUID: UInt32?
    }

    public func extent(_ mailbox: Int64) throws -> Extent {
        let row = try db.rows("SELECT COUNT(*), MIN(remote_uid), MAX(remote_uid) FROM messages WHERE mailbox = ?", [.int(mailbox)]).first ?? []
        return Extent(count: Int(row.first?.int ?? 0), minUID: row.count > 1 ? row[1].int.flatMap(UInt32.init(exactly:)) : nil,
                      maxUID: row.count > 2 ? row[2].int.flatMap(UInt32.init(exactly:)) : nil)
    }

    /// Every stored UID in a mailbox, lowest first.
    public func uids(_ mailbox: Int64) throws -> [UInt32] {
        try db.rows("SELECT remote_uid FROM messages WHERE mailbox = ? ORDER BY remote_uid", [.int(mailbox)]).compactMap { $0.first?.int.flatMap(UInt32.init(exactly:)) }
    }

    /// Counts stored UIDs without materializing the mailbox. Sync uses this to choose between a
    /// complete bounded walk and one rotating page for large non-CONDSTORE folders.
    public func uidCount(_ mailbox: Int64) throws -> Int {
        Int(try db.rows("SELECT COUNT(*) FROM messages WHERE mailbox = ?", [.int(mailbox)]).first?.first?.int ?? 0)
    }

    /// Reads one bounded UID page in ascending order. `after` is exclusive, so a caller can keep
    /// a durable rotation cursor without loading the whole mailbox into memory.
    public func uidPage(_ mailbox: Int64, after: UInt32? = nil, limit: Int = 500) throws -> [UInt32] {
        let bounded = max(1, min(limit, 10_000))
        let sql: String
        let arguments: [MailDatabase.Value]
        if let after {
            sql = "SELECT remote_uid FROM messages WHERE mailbox = ? AND remote_uid > ? ORDER BY remote_uid LIMIT ?"
            arguments = [.int(mailbox), .int(Int64(after)), .int(Int64(bounded))]
        } else {
            sql = "SELECT remote_uid FROM messages WHERE mailbox = ? ORDER BY remote_uid LIMIT ?"
            arguments = [.int(mailbox), .int(Int64(bounded))]
        }
        return try db.rows(sql, arguments).compactMap { $0.first?.int.flatMap(UInt32.init(exactly:)) }
    }

    /// Adds new messages, or updates the flags of ones already stored, in one transaction.
    public func upsert(_ messages: [SyncedMessage], into mailbox: Int64) throws {
        guard !messages.isEmpty else { return }
        try db.transaction {
            var subjects: [String: Int64] = [:], senders: [String: Int64] = [:]
            for message in messages {
                let subject = try subjects[message.subject] ?? intern(subject: message.subject)
                subjects[message.subject] = subject
                let senderKey = message.senderAddress + "\u{0}" + message.senderName
                let sender = try senders[senderKey] ?? intern(address: message.senderAddress, name: message.senderName)
                senders[senderKey] = sender
                try db.run("""
                    INSERT INTO messages (message_id, global_message_id, sender, subject_prefix, subject, date_received, mailbox,
                        read, flagged, deleted, size, conversation_id, remote_uid, answered, header_message_id, bulk)
                    VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(mailbox, remote_uid) DO UPDATE SET read = excluded.read, flagged = excluded.flagged,
                        answered = excluded.answered, deleted = CASE WHEN pending_hide = 1 THEN 1 ELSE excluded.deleted END
                    """, [.int(message.messageKey), .int(message.globalKey != 0 ? message.globalKey : message.messageKey), .int(sender),
                          .int(subject), .int(Int64(message.date.timeIntervalSince1970)), .int(mailbox),
                          .int(message.read ? 1 : 0), .int(message.flagged ? 1 : 0), .int(message.deleted ? 1 : 0), .int(message.size),
                          message.conversation != 0 ? .int(message.conversation) : .null, .int(Int64(message.uid)),
                          .int(message.answered ? 1 : 0), message.messageID.map { .text($0) } ?? .null, .int(message.bulk ? 1 : 0)])
                if let rowID = try db.rows("SELECT ROWID FROM messages WHERE mailbox = ? AND remote_uid = ?", [.int(mailbox), .int(Int64(message.uid))]).first?.first?.int {
                    try updateSearchIndex(rowID)
                }
            }
            try refreshCounts(mailbox)
        }
        touched()
    }

    private func intern(subject: String) throws -> Int64 {
        try db.rows("INSERT INTO subjects (subject) VALUES (?) ON CONFLICT(subject) DO UPDATE SET subject = excluded.subject RETURNING ROWID",
                    [.text(subject)]).first?.first?.int ?? 0
    }

    private func intern(address: String, name: String) throws -> Int64 {
        try db.rows("""
            INSERT INTO addresses (address, comment) VALUES (?, ?)
            ON CONFLICT(address, comment) DO UPDATE SET address = excluded.address RETURNING ROWID
            """, [.text(address), .text(name)]).first?.first?.int ?? 0
    }

    /// Flag changes the server reported. A message waiting to leave stays hidden.
    public func updateFlags(_ changes: [(uid: UInt32, flags: [String])], in mailbox: Int64) throws {
        guard !changes.isEmpty else { return }
        try db.transaction {
            for change in changes {
                var message = SyncedMessage(uid: change.uid, date: Date())
                message.apply(flags: change.flags)
                try db.run("""
                    UPDATE messages SET read = ?, flagged = ?, answered = ?, deleted = CASE WHEN pending_hide = 1 THEN 1 ELSE ? END
                    WHERE mailbox = ? AND remote_uid = ?
                    """, [.int(message.read ? 1 : 0), .int(message.flagged ? 1 : 0), .int(message.answered ? 1 : 0),
                          .int(message.deleted ? 1 : 0), .int(mailbox), .int(Int64(change.uid))])
            }
            try refreshCounts(mailbox)
        }
        touched()
    }

    /// Drops messages the server no longer has, with their bodies. `removedHere` means Jevcast just
    /// removed them on the server, such as by Empty, so the server's counts drop by the same. Rows
    /// a change in progress hid already dropped their count when they were hidden.
    public func remove(uids: [UInt32], from mailbox: Int64, removedHere: Bool = false) throws {
        guard !uids.isEmpty, let box = try self.mailbox(mailbox) else { return }
        try db.transaction {
            var hidden = 0, unread = 0
            for start in stride(from: 0, to: uids.count, by: 500) {
                let chunk = uids[start..<min(start + 500, uids.count)]
                let list = chunk.map { _ in "?" }.joined(separator: ",")
                let arguments: [MailDatabase.Value] = [.int(mailbox)] + chunk.map { .int(Int64($0)) }
                for row in try db.rows("SELECT ROWID, pending_hide, read FROM messages WHERE mailbox = ? AND remote_uid IN (\(list))", arguments) where row.count == 3 {
                    if let id = row[0].int { removeBody(id, mailboxRowID: mailbox, url: box.url) }
                    if (row[1].int ?? 0) != 0 { hidden += 1 } else if (row[2].int ?? 0) == 0 { unread += 1 }
                }
                try db.run("DELETE FROM messages WHERE mailbox = ? AND remote_uid IN (\(list))", arguments)
            }
            if removedHere { try adjustServerCounts(mailbox, total: hidden - uids.count, unread: -unread) }
            try refreshCounts(mailbox)
        }
        touched()
    }

    // MARK: Changes made here

    /// Where a message lives on the server, for a change the user makes.
    public struct Location: Sendable, Equatable {
        public let rowID: Int64
        public let uid: UInt32
        public let mailbox: Mailbox
        public let messageID: String?
        public let read: Bool
        public let flagged: Bool
        public let date: Date
    }

    public func location(of rowID: Int64) throws -> Location? {
        guard let row = try db.rows("SELECT mailbox, remote_uid, header_message_id, read, flagged, date_received FROM messages WHERE ROWID = ?",
                                    [.int(rowID)]).first,
              row.count == 6, let boxID = row[0].int, let uid = row[1].int.flatMap(UInt32.init(exactly:)), let box = try mailbox(boxID) else { return nil }
        return Location(rowID: rowID, uid: uid, mailbox: box, messageID: row[2].text, read: (row[3].int ?? 0) != 0, flagged: (row[4].int ?? 0) != 0,
                        date: Date(timeIntervalSince1970: row[5].double ?? 0))
    }

    /// The message's bytes from its `.emlx` file, without the byte count line, or nil.
    public func storedBody(_ rowID: Int64) throws -> Data? {
        guard try hasBody(rowID), let url = try bodyURL(rowID), let file = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let newline = file.firstIndex(of: 0x0A),
              let count = Int(String(decoding: file[file.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)) else { return file }
        let start = file.index(after: newline)
        return file[start..<min(file.endIndex, start + max(0, count))]
    }

    /// Changes read or flagged status here at once, before the server hears of it. A read change
    /// moves the server's unread count with it.
    public func setLocal(_ rowID: Int64, read: Bool? = nil, flagged: Bool? = nil) throws {
        let before = try state(rowID)
        if let read { try db.run("UPDATE messages SET read = ? WHERE ROWID = ?", [.int(read ? 1 : 0), .int(rowID)]) }
        if let flagged { try db.run("UPDATE messages SET flagged = ? WHERE ROWID = ?", [.int(flagged ? 1 : 0), .int(rowID)]) }
        touched()
        guard let before else { return }
        if let read, !before.hidden, before.read != read { try adjustServerCounts(before.mailbox, total: 0, unread: read ? -1 : 1) }
        try refreshCounts(before.mailbox)
    }

    /// Hides a message that is being moved or deleted, and shows it again if that fails. The
    /// server's counts for its mailbox move with it.
    public func setHidden(_ rowID: Int64, _ hidden: Bool) throws {
        let before = try state(rowID)
        try db.run("UPDATE messages SET pending_hide = ?, deleted = ? WHERE ROWID = ?", [.int(hidden ? 1 : 0), .int(hidden ? 1 : 0), .int(rowID)])
        touched()
        guard let before else { return }
        if before.hidden != hidden {
            let step = hidden ? -1 : 1
            try adjustServerCounts(before.mailbox, total: step, unread: before.read ? 0 : step)
        }
        try refreshCounts(before.mailbox)
    }

    private func state(_ rowID: Int64) throws -> (mailbox: Int64, read: Bool, hidden: Bool)? {
        guard let row = try db.rows("SELECT mailbox, read, pending_hide FROM messages WHERE ROWID = ?", [.int(rowID)]).first,
              row.count == 3, let mailbox = row[0].int else { return nil }
        return (mailbox, (row[1].int ?? 0) != 0, (row[2].int ?? 0) != 0)
    }

    // MARK: Bodies

    /// Where a message's body file goes: the path Apple Mail's layout gives its row.
    public func bodyURL(_ rowID: Int64) throws -> URL? {
        guard let row = try db.rows("SELECT m.mailbox, b.url FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox WHERE m.ROWID = ?", [.int(rowID)]).first,
              row.count == 2, let boxID = row[0].int, let url = row[1].text else { return nil }
        return bodyURL(rowID, mailboxRowID: boxID, url: url)
    }

    nonisolated func bodyURL(_ rowID: Int64, mailboxRowID: Int64, url: String) -> URL {
        URL(fileURLWithPath: MailMailbox(rowID: mailboxRowID, url: url, unread: 0, total: 0).folder(in: root.path), isDirectory: true)
            .appendingPathComponent(MailFiles.relativePaths(rowID: rowID)[0])
    }

    private func removeBody(_ rowID: Int64, mailboxRowID: Int64, url: String) {
        try? FileManager.default.removeItem(at: bodyURL(rowID, mailboxRowID: mailboxRowID, url: url))
    }

    public func hasBody(_ rowID: Int64) throws -> Bool {
        (try db.rows("SELECT has_body FROM messages WHERE ROWID = ?", [.int(rowID)]).first?.first?.int ?? 0) != 0
    }

    /// Writes the message as an `.emlx` file (a byte count line, then the message), keeps a
    /// bounded plain-text preview, and stores the full readable text in the private FTS source.
    public func saveBody(_ rowID: Int64, raw: Data, indexText: Bool = true) throws {
        guard let url = try bodyURL(rowID) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var file = Data("\(raw.count)\n".utf8)
        file.append(raw)
        guard FileManager.default.createFile(atPath: url.path, contents: file, attributes: [.posixPermissions: 0o600]) else {
            throw MailDatabase.Failure(text: "Could not save a message body.")
        }
        let bodyText = MIMEMessage.parse(raw)?.readableText ?? ""
        let text = indexText ? Self.summary(bodyText) : ""
        try db.transaction {
            let old = try db.rows("SELECT summary FROM messages WHERE ROWID = ?", [.int(rowID)]).first?.first?.int
            if let old { try db.run("DELETE FROM summaries WHERE ROWID = ?", [.int(old)]) }
            try db.run("INSERT INTO summaries (summary) VALUES (?)", [.text(text)])
            let summaryID = db.lastInsertID
            if indexText { try db.run("INSERT INTO message_body_text (message_rowid, text) VALUES (?, ?) ON CONFLICT(message_rowid) DO UPDATE SET text = excluded.text",
                       [.int(rowID), .text(bodyText)]) }
            try db.run("UPDATE messages SET summary = ?, has_body = 1 WHERE ROWID = ?", [.int(summaryID), .int(rowID)])
            try updateSearchIndex(rowID)
        }
        touched()
    }

    /// Saves full readable text for background search without retaining MIME attachment bytes.
    /// The message remains body-missing for the reader and can be fetched in full when opened.
    public func saveIndexedBodyText(_ rowID: Int64, text bodyText: String) throws {
        guard try bodyURL(rowID) != nil else { return }
        let preview = Self.summary(bodyText)
        try db.transaction {
            let old = try db.rows("SELECT summary FROM messages WHERE ROWID = ?", [.int(rowID)]).first?.first?.int
            if let old { try db.run("DELETE FROM summaries WHERE ROWID = ?", [.int(old)]) }
            try db.run("INSERT INTO summaries (summary) VALUES (?)", [.text(preview)])
            let summaryID = db.lastInsertID
            try db.run("INSERT INTO message_body_text (message_rowid, text) VALUES (?, ?) ON CONFLICT(message_rowid) DO UPDATE SET text = excluded.text",
                       [.int(rowID), .text(bodyText)])
            try db.run("UPDATE messages SET summary = ? WHERE ROWID = ?", [.int(summaryID), .int(rowID)])
            try updateSearchIndex(rowID)
        }
        touched()
    }

    /// The first few thousand characters, with runs of blank space closed up.
    static func summary(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(4000))
    }

    /// Messages without a body, up to `limit`, newest first, skipping ones over `maxSize`.
    /// When `within` is set, only that recent window is eligible. A nil window searches the
    /// complete local history while the result remains bounded by `limit`.
    public func missingBodies(in mailbox: Int64, within: Int? = nil, limit: Int, maxSize: Int64, requireRaw: Bool = false, requireIndex: Bool = true) throws -> [(rowID: Int64, uid: UInt32)] {
        let rows: [[MailDatabase.Value]]
        if let within {
            rows = try db.rows("""
            SELECT ROWID, remote_uid FROM (
                SELECT m.ROWID, m.remote_uid, m.has_body, m.size, m.date_received,
                       EXISTS (SELECT 1 FROM message_body_text bt WHERE bt.message_rowid = m.ROWID) AS body_indexed
                FROM messages m WHERE m.mailbox = ? AND m.deleted = 0
                ORDER BY date_received DESC LIMIT ?)
            WHERE ((\(requireRaw ? 1 : 0) = 1 AND has_body = 0) OR (\(requireIndex ? 1 : 0) = 1 AND body_indexed = 0))
              AND COALESCE(size, 0) <= ? ORDER BY date_received DESC LIMIT ?
            """, [.int(mailbox), .int(Int64(max(0, within))), .int(maxSize), .int(Int64(max(0, limit)))])
        } else {
            rows = try db.rows("""
                SELECT m.ROWID, m.remote_uid
                FROM messages m
                WHERE m.mailbox = ? AND m.deleted = 0
                  AND ((\(requireRaw ? 1 : 0) = 1 AND m.has_body = 0) OR (\(requireIndex ? 1 : 0) = 1 AND NOT EXISTS (SELECT 1 FROM message_body_text bt WHERE bt.message_rowid = m.ROWID)))
                  AND COALESCE(m.size, 0) <= ?
                ORDER BY m.date_received DESC LIMIT ?
                """, [.int(mailbox), .int(maxSize), .int(Int64(max(0, limit)))])
        }
        return rows.compactMap { row in
            guard row.count == 2, let id = row[0].int, let uid = row[1].int.flatMap(UInt32.init(exactly:)) else { return nil }
            return (id, uid)
        }
    }

    /// The stored row for a UID, for saving a body that sync fetched.
    public func rowID(uid: UInt32, in mailbox: Int64) throws -> Int64? {
        try db.rows("SELECT ROWID FROM messages WHERE mailbox = ? AND remote_uid = ?", [.int(mailbox), .int(Int64(uid))]).first?.first?.int
    }
}
