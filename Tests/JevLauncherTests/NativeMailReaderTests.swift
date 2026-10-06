import XCTest
import LauncherCore
@testable import JevLauncher

/// Jevcast's own store must read like Apple Mail's index: the mail window's list, search, and
/// bodies all go through `MailStore`, unchanged.
final class NativeMailReaderTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-reader-" + UUID().uuidString, isDirectory: true)
        let store = try NativeMailStore(root: root)
        let boxes = try await store.replaceMailboxes(account: "acct-1", with: [
            IMAPListEntry(flags: [], delimiter: "/", rawName: "INBOX"),
            IMAPListEntry(flags: ["\\Archive"], delimiter: "/", rawName: "Old Mail"),
            IMAPListEntry(flags: ["\\Sent"], delimiter: "/", rawName: "Sent Items"),
            IMAPListEntry(flags: ["\\Trash"], delimiter: "/", rawName: "Deleted Messages"),
            IMAPListEntry(flags: ["\\Noselect"], delimiter: "/", rawName: "Folders"),
        ])
        let inbox = try XCTUnwrap(boxes.first { $0.role == .inbox }), archive = try XCTUnwrap(boxes.first { $0.role == .archive })
        func message(_ uid: UInt32, _ subject: String, _ sender: String, _ date: Double, read: Bool, id: String) -> SyncedMessage {
            var message = SyncedMessage(uid: uid, date: Date(timeIntervalSince1970: date))
            message.subject = subject; message.senderName = sender; message.senderAddress = sender.lowercased() + "@example.com"
            message.read = read; message.messageID = id; message.messageKey = SyncedMessage.hash(id)
            return message
        }
        try await store.upsert([
            message(1, "Invoice for September", "Shop", 1_790_000_000, read: true, id: "<a@x>"),
            message(2, "Lunch on Friday", "Sam", 1_790_000_100, read: false, id: "<b@x>"),
            message(3, "Trip photos", "Ann", 1_790_000_200, read: false, id: "<c@x>"),
        ], into: inbox.rowID)
        // The same email in two mailboxes shows once in All Mail.
        try await store.upsert([message(7, "Lunch on Friday", "Sam", 1_790_000_100, read: false, id: "<b@x>")], into: archive.rowID)
        let found = try await store.rowID(uid: 2, in: inbox.rowID)
        let lunch = try XCTUnwrap(found)
        try await store.saveBody(lunch, raw: Data("From: Sam <sam@example.com>\r\nSubject: Lunch on Friday\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nThe ramen place at noon?\r\n".utf8))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testMailboxesListsAndSearch() throws {
        let path = root.path
        let boxes = try MailStore.mailboxes(root: path)
        XCTAssertEqual(boxes.count, 4, "A \\Noselect folder is left out")
        XCTAssertEqual(Set(boxes.map(\.role)), [.inbox, .archive, .sent, .trash])
        let inbox = try XCTUnwrap(boxes.first { $0.role == .inbox })
        XCTAssertEqual(inbox.accountID, "acct-1")
        XCTAssertEqual(inbox.unread, 2)
        XCTAssertEqual(MailMailbox.archive(for: "acct-1", in: boxes)?.name, "Old Mail")
        XCTAssertTrue(MailStore.hasMailboxDateIndex(root: path))
        XCTAssertTrue(try MailStore.supportsIndexedSearch(root: path))

        let list = try MailStore.page(root: path, MailModel.query(.inbox, "", boxes)).messages
        XCTAssertEqual(list.map(\.subject), ["Trip photos", "Lunch on Friday", "Invoice for September"])
        XCTAssertEqual(list.map(\.read), [false, false, true])
        XCTAssertEqual(list[1].sender, "Sam")

        let all = try MailStore.page(root: path, MailModel.query(.allMail, "", boxes)).messages
        XCTAssertEqual(all.filter { $0.subject == "Lunch on Friday" }.count, 1)

        XCTAssertEqual(try MailStore.page(root: path, MailModel.query(.inbox, "invoice", boxes)).messages.map(\.subject), ["Invoice for September"])
        let body = try MailStore.searchBodies(root: path, MailModel.query(.inbox, "ramen", boxes), budget: 1)
        XCTAssertEqual(body.messages.map(\.subject), ["Lunch on Friday"])
    }

    /// 30,000 messages written as sync writes them, then read as the mail window reads them.
    /// Prints the timings; the limits are loose so a busy machine does not fail the test.
    func testSpeedAtThirtyThousandMessages() async throws {
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-speed-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: big) }
        let store = try NativeMailStore(root: big)
        let boxes = try await store.replaceMailboxes(account: "acct-1", with: [
            IMAPListEntry(flags: [], delimiter: "/", rawName: "INBOX"), IMAPListEntry(flags: ["\\Archive"], delimiter: "/", rawName: "Archive"),
        ])
        let words = ["invoice", "lunch", "project", "update", "meeting", "report", "travel", "offer", "receipt", "welcome"]
        let start = CFAbsoluteTimeGetCurrent()
        for (index, box) in boxes.enumerated() {
            for batch in 0..<60 {
                let messages = (0..<250).map { n -> SyncedMessage in
                    let uid = UInt32(batch * 250 + n + 1)
                    var message = SyncedMessage(uid: uid, date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid) * 60 + Double(index)))
                    message.subject = "\(words[Int(uid) % 10]) \(words[Int(uid / 10) % 10]) number \(uid)"
                    message.senderName = "Person \(uid % 800)"; message.senderAddress = "person\(uid % 800)@example.com"
                    message.read = uid % 5 != 0; message.messageKey = SyncedMessage.hash("<\(index)-\(uid)@x>")
                    return message
                }
                try await store.upsert(messages, into: box.rowID)
            }
        }
        let writeMS = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let path = big.path
        let mailboxes = try MailStore.mailboxes(root: path)
        func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
            let begin = CFAbsoluteTimeGetCurrent()
            let value = try body()
            return (value, (CFAbsoluteTimeGetCurrent() - begin) * 1000)
        }
        _ = try MailStore.page(root: path, MailModel.query(.inbox, "", mailboxes))
        let (first, firstMS) = try timed { try MailStore.page(root: path, MailModel.query(.inbox, "", mailboxes)) }
        var next = MailModel.query(.inbox, "", mailboxes); next.before = first.last
        let (_, nextMS) = try timed { try MailStore.page(root: path, next) }
        let (all, allMS) = try timed { try MailStore.page(root: path, MailModel.query(.allMail, "", mailboxes)) }
        let (found, searchMS) = try timed { try MailStore.page(root: path, MailModel.query(.inbox, "receipt meeting", mailboxes)) }
        print(String(format: "Native store, 30000 messages: write %d ms, first page %.1f ms, next page %.1f ms, All Mail %.1f ms, search %.1f ms",
                     writeMS, firstMS, nextMS, allMS, searchMS))
        XCTAssertEqual(first.messages.count, MailStore.pageSize)
        XCTAssertEqual(all.messages.count, MailStore.pageSize)
        XCTAssertFalse(found.messages.isEmpty)
        XCTAssertLessThan(writeMS, 20_000)
        XCTAssertLessThan(firstMS, 50)
        XCTAssertLessThan(searchMS, 250)
    }

    func testBodiesAndRowStates() throws {
        let path = root.path
        let boxes = try MailStore.mailboxes(root: path)
        let inbox = try XCTUnwrap(boxes.first { $0.role == .inbox })
        let list = try MailStore.page(root: path, MailModel.query(.inbox, "", boxes)).messages
        let lunch = try XCTUnwrap(list.first { $0.subject == "Lunch on Friday" })
        XCTAssertEqual(MailStore.message(root: path, mailbox: inbox, rowID: lunch.rowID)?.plainText, "The ramen place at noon?\r\n")
        XCTAssertNil(MailStore.message(root: path, mailbox: inbox, rowID: list[0].rowID), "No body until it is downloaded")
        let states = try MailStore.states(root: path, rowIDs: list.map(\.rowID))
        XCTAssertEqual(states[lunch.rowID]?.read, false)
        XCTAssertEqual(states.count, 3)
    }
}
