import XCTest
import LauncherCore
@testable import JevLauncher

/// Paging, All Mail, search, query plans, and timings against a synthetic index shaped like a real 40k-message one.
final class MailPagingTests: XCTestCase {
    nonisolated(unsafe) private static var root: String!

    override class func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-perf-" + UUID().uuidString + "/V10").path
        root = try? MailFixture.build(root: dir)
    }
    override class func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        super.tearDown()
    }

    private var root: String { Self.root }
    private var boxes: [MailMailbox] { (try? MailStore.mailboxes(root: root)) ?? [] }
    private var inboxes: [Int64] { boxes.filter { $0.role == .inbox }.map(\.rowID) }
    private var allMail: [Int64] { boxes.filter(\.inAllMail).map(\.rowID) }

    func testFixtureHasTheRealisticLayout() throws {
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: boxes.map(\.rowID)), MailFixture.Layout().total)
        XCTAssertEqual(Set(inboxes), [1, 5], "Gmail INBOX and Exchange Inbox are both inboxes.")
        XCTAssertTrue(MailStore.hasMailboxDateIndex(root: root))
        XCTAssertGreaterThanOrEqual(boxes.count, 30)
    }

    func testPagesCoverEveryInboxMessageOnce() throws {
        var seen = Set<Int64>()
        var cursor: MailStore.Cursor?
        var previous: MailStore.Cursor?
        var pages = 0
        repeat {
            let page = try MailStore.page(root: root, .init(mailboxes: inboxes, before: cursor))
            for message in page.messages { XCTAssertTrue(seen.insert(message.rowID).inserted, "No row shows twice.") }
            if let first = page.messages.first, let previous {
                XCTAssertTrue(first.date.timeIntervalSince1970 < previous.date || (first.date.timeIntervalSince1970 == previous.date && first.rowID < previous.rowID))
            }
            XCTAssertLessThanOrEqual(page.messages.count, MailStore.pageSize)
            previous = page.last
            cursor = page.hasMore ? page.last : nil
            pages += 1
        } while cursor != nil && pages < 1_000
        XCTAssertEqual(seen.count, try MailStore.count(root: root, mailboxes: inboxes), "Paging reaches every inbox message; there is no cap.")
    }

    func testRefreshReadsOnlyNewerRows() throws {
        let page = try MailStore.page(root: root, .init(mailboxes: inboxes))
        let top = try XCTUnwrap(page.first)
        XCTAssertEqual(try MailStore.page(root: root, .init(mailboxes: inboxes, after: top)).messages, [])
        let older = page.messages[5]
        let newer = try MailStore.page(root: root, .init(mailboxes: inboxes, after: .init(older))).messages
        XCTAssertEqual(newer.map(\.rowID), page.messages.prefix(5).map(\.rowID))
    }

    func testAllMailShowsOneCopyAndPrefersTheInbox() throws {
        let query = MailStore.Query(mailboxes: allMail, dedupe: true, preferred: Set(inboxes))
        let page = try MailStore.page(root: root, query)
        XCTAssertFalse(allMail.contains(3), "Sent is not in All Mail.")
        XCTAssertFalse(allMail.contains(4), "Trash is not in All Mail.")
        XCTAssertEqual(Set(page.messages.map(\.messageKey)).count, page.messages.count, "One email shows once.")
        let gmail = page.messages.filter { $0.mailbox == 1 || $0.mailbox == 2 }
        XCTAssertFalse(gmail.isEmpty)
        // Every email with an inbox copy shows the inbox copy.
        let inboxKeys = Set(try MailStore.page(root: root, .init(mailboxes: [1], limit: 2000)).messages.map(\.messageKey))
        for message in gmail where inboxKeys.contains(message.messageKey) { XCTAssertEqual(message.mailbox, 1) }
        let expected = MailFixture.Layout()
        XCTAssertEqual(try MailStore.count(root: root, mailboxes: allMail, distinct: true),
                       expected.gmailInbox + expected.allMailOnly + expected.exchangeInbox + expected.projects + expected.perFolder * MailFixture.folders.count)
    }

    func testSearchMatchesBodyText() throws {
        let query = MailStore.Query(mailboxes: allMail, text: "body1234.", dedupe: true, preferred: Set(inboxes))
        XCTAssertEqual(try MailStore.page(root: root, query).messages, [], "The first phase reads subjects and senders only.")
        let result = try MailStore.searchBodies(root: root, query, budget: 60)
        XCTAssertTrue(result.done)
        let hits = result.messages
        XCTAssertFalse(hits.isEmpty, "A word only in Mail's body summary matches.")
        XCTAssertEqual(Set(hits.map(\.messageKey)).count, hits.count, "One email shows once.")
        let preview = try MailStore.page(root: root, .init(mailboxes: [], rowIDs: hits.map(\.rowID), includePreview: true)).messages
        XCTAssertTrue(preview.allSatisfy { $0.snippet.contains("body1234.") })
    }

    /// Body steps continue where the last stopped, so steps together read every row once.
    func testBodyStepsCoverTheScope() throws {
        let query = MailStore.Query(mailboxes: inboxes, text: "body12")
        var cursor: MailStore.Cursor?
        var found: [Int64] = []
        var steps = 0
        while true {
            let step = try MailStore.bodyStep(root: root, query, before: cursor)
            found += step.messages.map(\.rowID)
            steps += 1
            if step.done { break }
            cursor = step.cursor
        }
        XCTAssertEqual(steps, try MailStore.count(root: root, mailboxes: inboxes) / MailStore.bodyWindow + 1)
        XCTAssertEqual(Set(found).count, found.count)
        let all = try MailStore.searchBodies(root: root, query, budget: 60, maxMatches: .max)
        XCTAssertEqual(all.messages.map(\.rowID), found)
        let short = try MailStore.searchBodies(root: root, .init(mailboxes: inboxes, text: "the"), maxMatches: 50)
        XCTAssertFalse(short.done, "A common word stops once enough matches are found.")
        XCTAssertGreaterThanOrEqual(short.messages.count, 50)
    }

    func testStopCancelsAQuery() {
        XCTAssertThrowsError(try MailStore.page(root: root, .init(mailboxes: allMail, text: "zzz-no-match"), stop: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertNoThrow(try MailStore.page(root: root, .init(mailboxes: inboxes)), "The connection stays usable.")
    }

    /// Each mailbox is read through the (mailbox, date_received) index; no query scans the messages table.
    func testQueryPlansUseTheMailboxDateIndex() throws {
        let db = try MailStore.open(root)
        let cols = db.columns("messages")
        let top = try XCTUnwrap(try MailStore.page(root: root, .init(mailboxes: inboxes)).last)
        let queries: [MailStore.Query] = [
            .init(mailboxes: inboxes), .init(mailboxes: inboxes, before: top), .init(mailboxes: inboxes, after: top),
            .init(mailboxes: allMail, dedupe: true), .init(mailboxes: allMail, text: "invoice lunch"), .init(mailboxes: inboxes, unreadOnly: true)
        ]
        for query in queries {
            let (sql, arguments) = MailStore.pageSQL(cols, query)
            let plan = try db.rows("EXPLAIN QUERY PLAN " + XCTUnwrap(sql), arguments).compactMap { $0.last?.text }
            // Only the messages table matters; the small subject, address, and summary tables are read once per search.
            let scans = plan.filter { ($0 == "SCAN m" || $0.hasPrefix("SCAN m ") || $0.hasPrefix("SCAN messages")) && !$0.contains("INDEX") }
            XCTAssertEqual(scans, [], "Full scan in plan for \(query): \(plan)")
            XCTAssertTrue(plan.contains { $0.contains("messages_mailbox_date_received_index") }, "\(plan)")
        }
    }

    func testTimings() throws {
        let environment = ProcessInfo.processInfo.environment
        if (environment["DYLD_INSERT_LIBRARIES"] ?? "").contains("clang_rt") || environment["TSAN_OPTIONS"] != nil || environment["ASAN_OPTIONS"] != nil {
            throw XCTSkip("Timings mean nothing under a sanitizer.")
        }
        let t = try Self.measure(root: root)
        print("Mail timings on \(MailFixture.Layout().total) messages: first page \(t.first) ms, next page \(t.next) ms, search \(t.search) ms, rare-word search \(t.rareSearch) ms, body phase \(t.body) ms, rare-word body phase \(t.rareBody) ms, All Mail \(t.allMail) ms")
        // Targets are 30, 20, and 50 ms. The limits leave headroom for a busy test machine.
        XCTAssertLessThan(t.first, 60)
        XCTAssertLessThan(t.next, 40)
        XCTAssertLessThan(t.search, 100)
        XCTAssertLessThan(t.rareSearch, 100, "A word in almost no message still returns quickly.")
        XCTAssertLessThan(t.body, 250, "The body phase stops at its 150 ms budget or 200 matches.")
        XCTAssertLessThan(t.rareBody, 250)
        XCTAssertLessThan(t.allMail, 60)
    }

    /// Median milliseconds of several runs, with the connection already open.
    static func measure(root: String) throws -> (first: Double, next: Double, search: Double, rareSearch: Double, body: Double, rareBody: Double, allMail: Double) {
        let boxes = try MailStore.mailboxes(root: root)
        let inboxes = boxes.filter { $0.role == .inbox }.map(\.rowID)
        let all = boxes.filter(\.inAllMail).map(\.rowID)
        func median(_ body: () throws -> Void) rethrows -> Double {
            var times: [Double] = []
            for _ in 0..<7 {
                let start = CFAbsoluteTimeGetCurrent()
                try body()
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            return (times.sorted()[times.count / 2] * 10).rounded() / 10
        }
        let first = try MailStore.page(root: root, .init(mailboxes: inboxes))
        let firstTime = try median { _ = try MailStore.page(root: root, .init(mailboxes: inboxes)) }
        let nextTime = try median { _ = try MailStore.page(root: root, .init(mailboxes: inboxes, before: first.last)) }
        let common = MailStore.Query(mailboxes: all, text: "the", dedupe: true, preferred: Set(inboxes))
        let rare = MailStore.Query(mailboxes: all, text: "body1234.", dedupe: true, preferred: Set(inboxes))
        let searchTime = try median { _ = try MailStore.page(root: root, common) }
        // A word in only a few messages reads every row: the worst case.
        let rareTime = try median { _ = try MailStore.page(root: root, rare) }
        let bodyTime = try median { _ = try MailStore.searchBodies(root: root, common) }
        let rareBodyTime = try median { _ = try MailStore.searchBodies(root: root, rare) }
        let allTime = try median { _ = try MailStore.page(root: root, .init(mailboxes: all, dedupe: true, preferred: Set(inboxes))) }
        return (firstTime, nextTime, searchTime, rareTime, bodyTime, rareBodyTime, allTime)
    }
}

final class MailPlaceTests: XCTestCase {
    @MainActor func testPlacesMapToMailboxes() {
        let boxes = MailFixture.mailboxes.map { MailMailbox(rowID: $0.0, url: $0.1, unread: 0, total: 0) }
        XCTAssertEqual(MailModel.query(.inbox, "", boxes).mailboxes, [1, 5])
        let all = MailModel.query(.allMail, "x", boxes)
        XCTAssertEqual(all.mailboxes, [1, 2, 5, 6] + MailFixture.folders.map(\.0), "All Mail leaves out Sent and Trash.")
        XCTAssertTrue(all.dedupe)
        XCTAssertEqual(all.preferred, [1, 5])
        XCTAssertEqual(all.text, "x")
        XCTAssertEqual(MailModel.query(.mailbox(3), "", boxes).mailboxes, [3])
        XCTAssertEqual(MailModel.query(.inbox, "", boxes).limit, MailStore.pageSize)
        let model = MailModel(quill: { _ in throw CancellationError() }, quillAllowed: { false })
        XCTAssertEqual(model.place, .inbox, "Inbox stays the default.")
    }

    func testNewerThanCursor() {
        let message = MailSummary(rowID: 10, mailbox: 1, subject: "", senderName: "", senderAddress: "", snippet: "",
                                  date: Date(timeIntervalSince1970: 100), read: true, flagged: false, conversation: 10)
        XCTAssertTrue(MailModel.isNewer(message, than: .init(date: 100, rowID: 9)))
        XCTAssertFalse(MailModel.isNewer(message, than: .init(date: 100, rowID: 10)))
        XCTAssertFalse(MailModel.isNewer(message, than: .init(date: 101, rowID: 1)))
    }
}
