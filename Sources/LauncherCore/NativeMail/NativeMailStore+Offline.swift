import Foundation

extension NativeMailStore {
    // MARK: Offline policy

    public func offlinePolicy(for accountID: String) throws -> MailOfflinePolicy {
        guard !accountID.isEmpty else { return .default }
        guard let row = try db.rows("SELECT mode, recent_limit, selected_folders, download_attachments, index_bodies, paused FROM offline_policies WHERE account = ?", [.text(accountID)]).first,
              row.count == 6,
              let mode = row[0].text.flatMap(MailOfflineDownloadMode.init(rawValue:)) else {
            let policy = MailOfflinePolicy.default
            try saveOfflinePolicy(policy, for: accountID)
            return policy
        }
        let folders: Set<String>
        if let data = row[2].text?.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data) {
            folders = Set(decoded)
        } else {
            folders = []
        }
        return MailOfflinePolicy(mode: mode, recentMessageLimit: Int(row[1].int ?? 500),
                                 selectedFolderNames: folders, downloadAttachments: (row[3].int ?? 0) != 0,
                                 indexBodies: (row[4].int ?? 1) != 0, paused: (row[5].int ?? 0) != 0)
    }

    public func saveOfflinePolicy(_ policy: MailOfflinePolicy, for accountID: String) throws {
        guard !accountID.isEmpty else { throw MailDatabase.Failure(text: "An account is required for offline storage settings.") }
        let folders = try JSONEncoder().encode(Array(policy.selectedFolderNames).sorted())
        try db.run("""
            INSERT INTO offline_policies (account, mode, recent_limit, selected_folders, download_attachments, index_bodies, paused, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account) DO UPDATE SET mode = excluded.mode, recent_limit = excluded.recent_limit,
                selected_folders = excluded.selected_folders, download_attachments = excluded.download_attachments,
                index_bodies = excluded.index_bodies, paused = excluded.paused, updated_at = excluded.updated_at
            """, [.text(accountID), .text(policy.mode.rawValue), .int(Int64(policy.recentMessageLimit)),
                  .text(String(decoding: folders, as: UTF8.self)), .int(policy.downloadAttachments ? 1 : 0),
                  .int(policy.indexBodies ? 1 : 0), .int(policy.paused ? 1 : 0), .double(Date().timeIntervalSinceReferenceDate)])
        touched()
    }

    public func offlinePolicies(for accountIDs: [String]) throws -> [String: MailOfflinePolicy] {
        var result: [String: MailOfflinePolicy] = [:]
        for accountID in Set(accountIDs) { result[accountID] = try offlinePolicy(for: accountID) }
        return result
    }

    // MARK: Coverage and cache size

    public func offlineCoverage(accountID: String? = nil) throws -> [MailOfflineMailboxCoverage] {
        let rows: [[MailDatabase.Value]]
        if let accountID {
            rows = try db.rows("""
                SELECT b.ROWID, b.account, b.name, b.total_count, b.server_total, b.complete,
                       (SELECT COUNT(*) FROM message_body_text bt JOIN messages m ON m.ROWID = bt.message_rowid WHERE m.mailbox = b.ROWID),
                       (SELECT COUNT(*) FROM messages m WHERE m.mailbox = b.ROWID AND m.deleted = 0)
                FROM mailboxes b WHERE b.account = ? ORDER BY b.ROWID
                """, [.text(accountID)])
        } else {
            rows = try db.rows("""
                SELECT b.ROWID, b.account, b.name, b.total_count, b.server_total, b.complete,
                       (SELECT COUNT(*) FROM message_body_text bt JOIN messages m ON m.ROWID = bt.message_rowid WHERE m.mailbox = b.ROWID),
                       (SELECT COUNT(*) FROM messages m WHERE m.mailbox = b.ROWID AND m.deleted = 0)
                FROM mailboxes b ORDER BY b.account, b.ROWID
                """)
        }
        return try rows.compactMap { row in
            guard row.count == 8, let id = row[0].int, let account = row[1].text, let name = row[2].text else { return nil }
            let boxURL = try db.rows("SELECT url FROM mailboxes WHERE ROWID = ?", [.int(id)]).first?.first?.text
            let lastError = try db.rows("SELECT last_error FROM offline_actions WHERE account = ? AND mailbox_name = ? AND last_error IS NOT NULL ORDER BY updated_at DESC LIMIT 1", [.text(account), .text(name)]).first?.first?.text
            return MailOfflineMailboxCoverage(id: id, accountID: account, name: name,
                                              downloadedHeaders: Int(row[3].int ?? 0), serverTotal: row[4].int.map(Int.init),
                                              indexedBodies: Int(row[6].int ?? 0), bodyCandidates: Int(row[7].int ?? 0),
                                              completeHistory: (row[5].int ?? 0) != 0,
                                              storageBytes: boxURL.map { Self.directoryBytes(bodyFolder(mailboxRowID: id, url: $0)) } ?? 0,
                                              lastError: lastError)
        }
    }

    public func offlineStorage(accountID: String? = nil) throws -> MailOfflineStorageReport {
        let bytes: Int64
        if let accountID, Self.isSafeName(accountID) {
            bytes = Self.directoryBytes(root.appendingPathComponent(accountID, isDirectory: true))
        } else if accountID == nil {
            bytes = Self.directoryBytes(root)
        } else {
            bytes = 0
        }
        let arguments: [MailDatabase.Value] = accountID.map { [.text($0)] } ?? []
        let bodySQL = accountID == nil
            ? "SELECT COUNT(*) FROM messages WHERE has_body = 1"
            : "SELECT COUNT(*) FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox WHERE m.has_body = 1 AND b.account = ?"
        let bodies = Int(try db.rows(bodySQL, arguments).first?.first?.int ?? 0)
        // Attachments are embedded in the raw message body for an opened message. They are not
        // counted as separately cached attachments, so this number cannot overstate coverage.
        return MailOfflineStorageReport(accountID: accountID, bytes: bytes, cachedMessageBodies: bodies, cachedAttachments: 0)
    }

    /// Removes downloaded bodies and their full-text rows only. Headers, drafts, and queued
    /// actions are retained, so the next reconnect can continue safely.
    public func clearOfflineCache(accountID: String? = nil) throws {
        let rows: [[MailDatabase.Value]]
        if let accountID {
            rows = try db.rows("SELECT m.ROWID, b.ROWID, b.url FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox WHERE b.account = ? AND (m.has_body = 1 OR EXISTS (SELECT 1 FROM message_body_text bt WHERE bt.message_rowid = m.ROWID))", [.text(accountID)])
        } else {
            rows = try db.rows("SELECT m.ROWID, b.ROWID, b.url FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox WHERE m.has_body = 1 OR EXISTS (SELECT 1 FROM message_body_text bt WHERE bt.message_rowid = m.ROWID)")
        }
        try db.transaction {
            for row in rows where row.count == 3 {
                guard let rowID = row[0].int, let mailboxID = row[1].int, let url = row[2].text else { continue }
                let fileURL = bodyURL(rowID, mailboxRowID: mailboxID, url: url)
                if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
                try db.run("DELETE FROM message_body_text WHERE message_rowid = ?", [.int(rowID)])
                try db.run("DELETE FROM summaries WHERE ROWID = (SELECT summary FROM messages WHERE ROWID = ?)", [.int(rowID)])
                try db.run("UPDATE messages SET summary = NULL, has_body = 0 WHERE ROWID = ?", [.int(rowID)])
                try updateSearchIndex(rowID)
            }
        }
        if !rows.isEmpty { touched() }
    }

    private static func directoryBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Durable action queue

    public func enqueueOfflineAction(_ action: MailOfflineAction) throws -> MailOfflineAction {
        guard ![.move, .archive].contains(action.kind) || action.destinationMailboxName != nil else {
            throw MailDatabase.Failure(text: "A move needs a destination mailbox.")
        }
        // Repeated read/flag clicks collapse to the latest desired value. A move is also
        // coalesced by identity, but its destination is never silently changed once review is
        // required.
        if let existing = try offlineActions(accountID: action.accountID).first(where: {
            $0.kind == action.kind && $0.mailboxName == action.mailboxName && $0.uidValidity == action.uidValidity && $0.uid == action.uid && $0.state != .review
        }) {
            var updated = existing
            updated.desiredValue = action.desiredValue
            updated.lastError = action.lastError
            updated.state = action.state
            updated.updatedAt = Date()
            try updateOfflineAction(updated)
            return updated
        }
        try db.run("""
            INSERT INTO offline_actions (id, account, kind, mailbox_name, uid_validity, uid, message_id,
                destination_mailbox_name, destination_uid_validity, desired_value, state, attempts, last_error, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(action.id.uuidString), .text(action.accountID), .text(action.kind.rawValue), .text(action.mailboxName),
                  .int(Int64(action.uidValidity)), .int(Int64(action.uid)), action.messageID.map { .text($0) } ?? .null,
                  action.destinationMailboxName.map { .text($0) } ?? .null, action.destinationUIDValidity.map { .int(Int64($0)) } ?? .null,
                  action.desiredValue.map { .int($0 ? 1 : 0) } ?? .null, .text(action.state.rawValue), .int(Int64(action.attempts)),
                  action.lastError.map { .text($0) } ?? .null, .double(action.createdAt.timeIntervalSinceReferenceDate), .double(action.updatedAt.timeIntervalSinceReferenceDate)])
        touched()
        return action
    }

    public func offlineActions(accountID: String? = nil, states: Set<MailOfflineActionState> = [.pending, .failed, .review]) throws -> [MailOfflineAction] {
        var clauses: [String] = []
        var arguments: [MailDatabase.Value] = []
        if let accountID { clauses.append("account = ?"); arguments.append(.text(accountID)) }
        if !states.isEmpty {
            clauses.append("state IN (" + states.map { _ in "?" }.joined(separator: ",") + ")")
            arguments += states.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
        }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let sql = "SELECT id, account, kind, mailbox_name, uid_validity, uid, message_id, destination_mailbox_name, destination_uid_validity, desired_value, state, attempts, last_error, created_at, updated_at FROM offline_actions" + whereClause + " ORDER BY created_at"
        return try db.rows(sql, arguments).compactMap(Self.offlineAction)
    }

    public func offlineQueueStatus(accountID: String? = nil) throws -> MailOfflineQueueStatus {
        let actions = try offlineActions(accountID: accountID)
        return MailOfflineQueueStatus(pending: actions.filter { $0.state == .pending }.count,
                                      failed: actions.filter { $0.state == .failed }.count,
                                      review: actions.filter { $0.state == .review }.count,
                                      lastError: actions.reversed().compactMap(\.lastError).first)
    }

    public func updateOfflineAction(_ action: MailOfflineAction) throws {
        try db.run("""
            UPDATE offline_actions SET desired_value = ?, state = ?, attempts = ?, last_error = ?, updated_at = ? WHERE id = ?
            """, [action.desiredValue.map { .int($0 ? 1 : 0) } ?? .null, .text(action.state.rawValue), .int(Int64(action.attempts)),
                  action.lastError.map { .text($0) } ?? .null, .double(action.updatedAt.timeIntervalSinceReferenceDate), .text(action.id.uuidString)])
        touched()
    }

    public func removeOfflineAction(_ id: UUID) throws {
        try db.run("DELETE FROM offline_actions WHERE id = ?", [.text(id.uuidString)])
        if db.changes > 0 { touched() }
    }

    private static func offlineAction(_ row: [MailDatabase.Value]) -> MailOfflineAction? {
        guard row.count == 15, let id = row[0].text.flatMap(UUID.init(uuidString:)), let account = row[1].text,
              let kind = row[2].text.flatMap(MailOfflineActionKind.init(rawValue:)), let mailbox = row[3].text,
              let validity = row[4].int.flatMap(UInt32.init(exactly:)), let uid = row[5].int.flatMap(UInt32.init(exactly:)),
              let state = row[10].text.flatMap(MailOfflineActionState.init(rawValue:)) else { return nil }
        return MailOfflineAction(id: id, accountID: account, kind: kind, mailboxName: mailbox, uidValidity: validity, uid: uid,
                                messageID: row[6].text, destinationMailboxName: row[7].text,
                                destinationUIDValidity: row[8].int.flatMap(UInt32.init(exactly:)), desiredValue: row[9].int.map { $0 != 0 },
                                state: state, attempts: Int(row[11].int ?? 0), lastError: row[12].text,
                                createdAt: Date(timeIntervalSinceReferenceDate: row[13].double ?? 0), updatedAt: Date(timeIntervalSinceReferenceDate: row[14].double ?? 0))
    }
}
