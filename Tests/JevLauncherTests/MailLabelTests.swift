import XCTest
import SQLite3
import LauncherCore
@testable import JevLauncher

/// A synthetic index with a Gmail account, whose rows all sit in All Mail and reach Inbox, Sent,
/// and Important through `labels`, and a Yahoo account, whose rows sit in their own mailboxes.
enum MailLabelFixture {
    struct Layout {
        var gmail = 30_000
        var yahooInbox = 8_000
        var yahooArchive = 2_000
        /// Label rows: every `inboxEvery`th Gmail row is in Inbox, and so on.
        var inboxEvery = 3, sentEvery = 10, importantEvery = 6
        var labelIndex = true
        /// Column names, to check that they are read from the index.
        var messageColumn = "message_id", mailboxColumn = "mailbox_id"
        var foreignKeys = true
    }
    // 1 Gmail INBOX, 2 All Mail, 3 Sent Mail, 4 Important, 5 Yahoo Inbox, 6 Yahoo Archive.
    static let mailboxes: [(Int64, String)] = [
        (1, "imap://GMAIL-1/INBOX"), (2, "imap://GMAIL-1/%5BGmail%5D/All%20Mail"), (3, "imap://GMAIL-1/%5BGmail%5D/Sent%20Mail"),
        (4, "imap://GMAIL-1/%5BGmail%5D/Important"), (5, "imap://YAHOO-2/Inbox"), (6, "imap://YAHOO-2/Archive")
    ]

    static func gmailRows(_ l: Layout) -> ClosedRange<Int> { 1...l.gmail }
    static func inInbox(_ i: Int, _ l: Layout) -> Bool { i % l.inboxEvery == 0 }
    static func unread(_ i: Int) -> Bool { i % 4 == 0 }

    @discardableResult
    static func build(root: String, layout l: Layout = Layout()) throws -> String {
        try FileManager.default.createDirectory(atPath: root + "/MailData", withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(root + "/MailData/Envelope Index", &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
        let m = l.messageColumn, b = l.mailboxColumn
        let references = l.foreignKeys ? ("REFERENCES messages(ROWID)", "REFERENCES mailboxes(ROWID)") : ("", "")
        exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT UNIQUE, total_count INTEGER, unread_count INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER, global_message_id INTEGER,
            sender INTEGER, subject INTEGER, summary INTEGER, date_received INTEGER, mailbox INTEGER,
            read INTEGER, flagged INTEGER, deleted INTEGER, conversation_id INTEGER);
        CREATE INDEX messages_mailbox_date_received_index ON messages(mailbox, date_received);
        CREATE INDEX messages_global_message_id_index ON messages(global_message_id);
        CREATE TABLE labels (\(m) INTEGER NOT NULL \(references.0), \(b) INTEGER NOT NULL \(references.1),
            PRIMARY KEY (\(m), \(b))) WITHOUT ROWID;
        \(l.labelIndex ? "CREATE INDEX labels_mailbox_index ON labels(\(b));" : "")
        CREATE TABLE server_labels (ROWID INTEGER PRIMARY KEY);
        BEGIN;
        """)
        // Mail's own counts for the Gmail inbox are left at 0, so a test sees the label count.
        for (id, url) in mailboxes { exec("INSERT INTO mailboxes VALUES (\(id), '\(url)', 0, 0)") }
        for i in 1...50 { exec("INSERT INTO subjects VALUES (\(i), 'subject \(i)')"); exec("INSERT INTO addresses VALUES (\(i), 'p\(i)@example.com', 'P \(i)')") }
        var insert: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO messages (ROWID, message_id, global_message_id, sender, subject, summary, date_received, mailbox, read, flagged, deleted, conversation_id)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 0, ?)
            """, -1, &insert, nil)
        var label: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO labels VALUES (?, ?)", -1, &label, nil)
        func add(_ id: Int, _ box: Int64, date: Int64) {
            let values: [Int64] = [Int64(id), Int64(id) * 31, Int64(id) + 5_000_000, Int64(id % 50 + 1), Int64(id % 50 + 1), date, box,
                                   unread(id) ? 0 : 1, id % 7 == 0 ? 1 : 0, Int64(id)]
            for (index, value) in values.enumerated() { sqlite3_bind_int64(insert, Int32(index + 1), value) }
            sqlite3_step(insert); sqlite3_reset(insert)
        }
        func tag(_ id: Int, _ box: Int64) {
            sqlite3_bind_int64(label, 1, Int64(id)); sqlite3_bind_int64(label, 2, box)
            sqlite3_step(label); sqlite3_reset(label)
        }
        let start: Int64 = 1_700_000_000
        // Dates interleave the two accounts and repeat, so the ROWID tie-break matters.
        for i in gmailRows(l) {
            add(i, 2, date: start + Int64(i / 2) * 60)
            if inInbox(i, l) { tag(i, 1) }
            if i % l.sentEvery == 0 { tag(i, 3) }
            if i % l.importantEvery == 0 { tag(i, 4) }
        }
        for n in 0..<(l.yahooInbox + l.yahooArchive) {
            let id = l.gmail + 1 + n
            add(id, n < l.yahooInbox ? 5 : 6, date: start + Int64(n) * 90)
        }
        sqlite3_finalize(insert); sqlite3_finalize(label)
        exec("COMMIT; PRAGMA wal_checkpoint(TRUNCATE);")
        return root
    }
}

final class MailLabelTests: XCTestCase {
    private var dirs: [String] = []
    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }
    private func make(_ layout: MailLabelFixture.Layout = .init()) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-labels-" + UUID().uuidString).path
        dirs.append(dir)
        return try MailLabelFixture.build(root: dir + "/V10", layout: layout)
    }
    private static let small = MailLabelFixture.Layout(gmail: 1_200, yahooInbox: 300, yahooArchive: 100)

    private func write(_ root: String, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(MailStore.indexPath(root), &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteReader.Failure(text: String(cString: sqlite3_errmsg(db)))
        }
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for the mail model")
    }

    func testEmptyGmailInboxDoesNotRestoreStaleUnreadCount() throws {
        let root = try make(.init(gmail: 12, yahooInbox: 3, yahooArchive: 1))
        try write(root, "UPDATE mailboxes SET unread_count = 9 WHERE ROWID IN (1, 5)")
        XCTAssertEqual(try MailStore.mailboxes(root: root).first { $0.rowID == 1 }?.unread, 1)
        try write(root, "DELETE FROM labels WHERE mailbox_id = 1")
        let boxes = try MailStore.mailboxes(root: root)
        XCTAssertEqual(boxes.first { $0.rowID == 1 }?.unread, 0)
        XCTAssertEqual(boxes.first { $0.rowID == 5 }?.unread, 9)
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: [1]), 0)
    }

    @MainActor func testRefreshFindsOlderNewLabelMembersWithoutLosingPages() async throws {
        try skipLiveMailModelOnCI()
        let root = try make(.init(gmail: 1_500, yahooInbox: 0, yahooArchive: 0))
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, statusProvider: { .ready(root: root) })
        model.refreshStatus()
        try await wait { model.messages.count == 200 && !model.isLoading }
        model.loadNextPage()
        try await wait { model.messages.count == 400 && !model.isLoading }
        let selected = try XCTUnwrap(model.messages.last?.rowID)
        model.select(selected, byUser: false)
        let bottom = model.bottom
        try write(root, "INSERT INTO labels VALUES (1001, 1); DELETE FROM labels WHERE message_id = 1200 AND mailbox_id = 1")
        XCTAssertTrue(model.refresh())
        try await wait { !model.isLoading }
        XCTAssertTrue(model.messages.contains { $0.rowID == 1001 })
        XCTAssertFalse(model.messages.contains { $0.rowID == 1200 })
        XCTAssertEqual(model.messages.count, 400)
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.bottom, bottom)
        XCTAssertEqual(Set(model.messages.map(\.rowID)).count, model.messages.count)
        model.loadNextPage()
        try await wait { !model.isLoading && !model.hasMore }
        XCTAssertEqual(model.messages.count, 500)
        // This row is older than the last cursor. A fully loaded list must discover it too.
        try write(root, "INSERT INTO labels VALUES (1, 1)")
        XCTAssertTrue(model.refresh())
        try await wait { !model.isLoading }
        XCTAssertEqual(model.messages.count, 501)
        XCTAssertEqual(model.messages.last?.rowID, 1)
        XCTAssertEqual(model.messages, model.messages.sorted { MailModel.isNewer($0, than: .init($1)) })
    }

    @MainActor func testRefreshRestartsBodySearchForNewLabelMembers() async throws {
        try skipLiveMailModelOnCI()
        let root = try make(.init(gmail: 12, yahooInbox: 0, yahooArchive: 0))
        try write(root, """
            INSERT INTO summaries VALUES (1, 'body-only-token');
            UPDATE messages SET summary = 1;
            UPDATE subjects SET subject = 'body-only-token' WHERE ROWID = 13;
            """)
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, statusProvider: { .ready(root: root) })
        model.refreshStatus()
        try await wait { model.messages.count == 4 && !model.isLoading }
        model.search = "body-only-token"
        try await wait { model.bodySearch == .done && !model.isLoading }
        XCTAssertEqual(model.messages.count, 4)
        try write(root, "INSERT INTO labels VALUES (1, 1)")
        XCTAssertTrue(model.refresh())
        try await wait { !model.isLoading }
        XCTAssertEqual(model.messages.count, 5)
        XCTAssertEqual(model.messages.last?.rowID, 1)
        XCTAssertEqual(model.messages.last?.labels, [1])
    }

    private func walk(_ root: String, _ query: MailStore.Query) throws -> [MailSummary] {
        var all: [MailSummary] = []
        var query = query
        for _ in 0..<1_000 {
            let page = try MailStore.page(root: root, query)
            all += page.messages
            guard page.hasMore, let last = page.last else { break }
            query.before = last
        }
        return all
    }

    func testFindsTheLabelColumns() throws {
        let root = try make(Self.small)
        let db = try MailStore.open(root)
        XCTAssertEqual(MailStore.labelTable(db), .init(message: "message_id", mailbox: "mailbox_id"))
        let other = try make(.init(gmail: 30, yahooInbox: 3, yahooArchive: 1, messageColumn: "message", mailboxColumn: "mailbox", foreignKeys: false))
        XCTAssertEqual(MailStore.labelTable(try MailStore.open(other)), .init(message: "message", mailbox: "mailbox"))
        XCTAssertEqual(try MailStore.count(root: other, mailboxes: [1]), 10)
    }

    func testInboxIncludesGmailLabelMembersOncePerPage() throws {
        let root = try make(Self.small)
        let l = Self.small
        let boxes = try MailStore.mailboxes(root: root)
        let query = MailModel.query(.inbox, "", boxes)
        XCTAssertEqual(Set(query.mailboxes), [1, 5])
        let rows = try walk(root, query)
        let gmail = MailLabelFixture.gmailRows(l).filter { MailLabelFixture.inInbox($0, l) }.count
        XCTAssertEqual(rows.count, gmail + l.yahooInbox)
        XCTAssertEqual(Set(rows.map(\.rowID)).count, rows.count, "No row shows twice.")
        XCTAssertEqual(rows, rows.sorted { MailModel.isNewer($0, than: .init($1)) }, "Newest first across pages.")
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: query.mailboxes), rows.count)
        let row = try XCTUnwrap(rows.first { $0.rowID <= l.gmail })
        XCTAssertEqual(row.mailbox, 2, "The row's own mailbox stays All Mail, where its file is.")
        XCTAssertTrue(row.labels.contains(1))
        XCTAssertEqual(MailMailbox.actionTarget(for: row, in: boxes)?.rowID, 1, "Actions address the Gmail Inbox.")
        XCTAssertEqual(MailMailbox.actionTarget(for: row, viewing: 2, in: boxes)?.rowID, 2)
        let yahoo = try XCTUnwrap(rows.first { $0.rowID > l.gmail })
        XCTAssertEqual(yahoo.mailbox, 5)
        XCTAssertEqual(MailMailbox.actionTarget(for: yahoo, in: boxes)?.rowID, 5)
    }

    func testAllMailDoesNotDoubleCount() throws {
        let root = try make(Self.small)
        let l = Self.small
        let boxes = try MailStore.mailboxes(root: root)
        let query = MailModel.query(.allMail, "", boxes)
        let rows = try walk(root, query)
        XCTAssertEqual(rows.count, l.gmail + l.yahooInbox + l.yahooArchive)
        XCTAssertEqual(Set(rows.map(\.rowID)).count, rows.count)
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: query.mailboxes), rows.count)
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: query.mailboxes, distinct: true), rows.count)
        // Sent is outside All Mail, but its label members are still counted by role.
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: [3]), l.gmail / l.sentEvery)
    }

    func testUnreadAndFlaggedUseLabels() throws {
        let root = try make(Self.small)
        let l = Self.small
        let boxes = try MailStore.mailboxes(root: root)
        let expected = MailLabelFixture.gmailRows(l).filter { MailLabelFixture.inInbox($0, l) && MailLabelFixture.unread($0) }.count
        XCTAssertEqual(boxes.first { $0.rowID == 1 }?.unread, expected, "The Gmail inbox's unread count reads the labels.")
        XCTAssertEqual(boxes.first { $0.rowID == 5 }?.unread, 0, "Other accounts keep Mail's own count.")
        let unread = try walk(root, MailModel.query(.unread, "", boxes))
        let yahooUnread = (0..<l.yahooInbox).filter { MailLabelFixture.unread(l.gmail + 1 + $0) }.count
        let allGmailUnread = MailLabelFixture.gmailRows(l).filter(MailLabelFixture.unread).count
        let yahooArchiveUnread = (0..<l.yahooArchive).filter { MailLabelFixture.unread(l.gmail + l.yahooInbox + 1 + $0) }.count
        XCTAssertEqual(unread.count, allGmailUnread + yahooUnread + yahooArchiveUnread)
        XCTAssertTrue(unread.allSatisfy { !$0.read })
        let flagged = try walk(root, MailModel.query(.flagged, "", boxes))
        XCTAssertEqual(Set(flagged.map(\.rowID)).count, flagged.count)
        XCTAssertTrue(flagged.allSatisfy(\.flagged))
    }

    func testLabelMailboxAndSearch() throws {
        let root = try make(Self.small)
        let important = try walk(root, .init(mailboxes: [4]))
        XCTAssertEqual(important.count, Self.small.gmail / Self.small.importantEvery)
        let boxes = try MailStore.mailboxes(root: root)
        let hits = try walk(root, MailModel.query(.inbox, "subject 7", boxes))
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains { $0.rowID <= Self.small.gmail }, "Search finds Gmail inbox rows.")
        let body = try MailStore.searchBodies(root: root, MailModel.query(.inbox, "zzz-none", boxes), budget: 10)
        XCTAssertTrue(body.done)
    }

    func testRefreshKeepsGmailInboxRows() throws {
        let root = try make(Self.small)
        let boxes = try MailStore.mailboxes(root: root)
        let query = MailModel.query(.inbox, "", boxes)
        let page = try MailStore.page(root: root, query)
        let ids = page.messages.map(\.rowID)
        let states = try MailStore.states(root: root, rowIDs: ids)
        let kept = MailModel.refreshed(page.messages, states: states, requested: Set(ids), query: query, selectedID: nil)
        XCTAssertEqual(kept.map(\.rowID), ids)
    }

    func testMessageFileComesFromTheRowsOwnMailbox() throws {
        let root = try make(Self.small)
        let boxes = try MailStore.mailboxes(root: root)
        let row = try XCTUnwrap(try MailStore.page(root: root, .init(mailboxes: [1])).messages.first)
        let own = try XCTUnwrap(boxes.first { $0.rowID == row.mailbox })
        let file = own.folder(in: root) + "/" + MailFiles.relativePaths(rowID: row.rowID)[0]
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file, contents: Data("1\nx".utf8))
        XCTAssertEqual(MailStore.messageFile(root: root, mailbox: own, rowID: row.rowID), file)
    }

    func testIndexWithoutLabelsKeepsDirectPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-nolabels-" + UUID().uuidString).path
        dirs.append(dir)
        let root = try MailFixture.build(root: dir + "/V10", layout: .init(gmailInbox: 50, allMailOnly: 20, sent: 5, trash: 5, exchangeInbox: 10, projects: 5, perFolder: 1))
        XCTAssertNil(MailStore.labelTable(try MailStore.open(root)))
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: [1, 5]), 60)
        XCTAssertEqual(try walk(root, .init(mailboxes: [1, 5])).count, 60)
    }

    /// 40k messages, 20k label rows: the first page stays under 40 ms, with or without an index on the label mailbox.
    /// A shared CI machine gets twice that. One run's median was 40.6 ms and failed the exact limit.
    func testFirstPageIsFast() throws {
        for indexed in [true, false] {
            let layout = MailLabelFixture.Layout(gmail: 30_000, yahooInbox: 8_000, yahooArchive: 2_000,
                                                 inboxEvery: 3, sentEvery: 6, importantEvery: 6, labelIndex: indexed)
            let root = try make(layout)
            let db = try MailStore.open(root)
            XCTAssertEqual(try db.rows("SELECT COUNT(*) FROM labels").first?.first?.int, 20_000)
            XCTAssertEqual(try db.rows("SELECT COUNT(*) FROM messages").first?.first?.int, 40_000)
            let boxes = try MailStore.mailboxes(root: root)
            func median(_ body: () throws -> Void) rethrows -> Double {
                var times: [Double] = []
                for _ in 0..<7 {
                    let start = CFAbsoluteTimeGetCurrent()
                    try body()
                    times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
                return times.sorted()[3]
            }
            let inbox = MailModel.query(.inbox, "", boxes), all = MailModel.query(.allMail, "", boxes)
            let first = try MailStore.page(root: root, inbox)
            XCTAssertEqual(first.messages.count, MailStore.pageSize)
            let inboxMs = try median { _ = try MailStore.page(root: root, inbox) }
            let nextMs = try median { _ = try MailStore.page(root: root, inbox.after(nil, before: first.last)) }
            let allMs = try median { _ = try MailStore.page(root: root, all) }
            let boxesMs = try median { _ = try MailStore.mailboxes(root: root) }
            let budget: Double = ProcessInfo.processInfo.environment["CI"] == "true" ? 80 : 40
            print("labels indexed \(indexed): inbox \(inboxMs) ms, next \(nextMs) ms, All Mail \(allMs) ms, mailboxes \(boxesMs) ms")
            XCTAssertLessThan(inboxMs, budget)
            XCTAssertLessThan(nextMs, budget)
            XCTAssertLessThan(allMs, budget)
            XCTAssertLessThan(boxesMs, budget)
        }
    }
}
