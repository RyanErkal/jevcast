import XCTest
import SQLite3
import LauncherCore
@testable import JevLauncher

final class MailStoreTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-" + UUID().uuidString + "/V10").path
        try FileManager.default.createDirectory(atPath: root + "/MailData", withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root + "/MailData/Envelope Index", &db), SQLITE_OK)
        let sql = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER, unread_count INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, mailbox INTEGER, subject INTEGER, subject_prefix TEXT, sender INTEGER,
                               summary INTEGER, date_received INTEGER, read INTEGER, flagged INTEGER, deleted INTEGER, conversation_id INTEGER);
        INSERT INTO mailboxes VALUES (1, 'imap://ACC/INBOX', 3, 1), (2, 'imap://ACC/Archive', 1, 0);
        INSERT INTO subjects VALUES (1, 'Invoice 50% off'), (2, 'Lunch'), (3, 'Old news');
        INSERT INTO addresses VALUES (1, 'billing@shop.example', 'Shop'), (2, 'sam@example.com', 'Sam');
        INSERT INTO summaries VALUES (1, 'Your invoice is ready'), (2, 'Friday works');
        INSERT INTO messages VALUES (1001, 1, 1, NULL, 1, 1, 1790000000, 0, 0, 0, 7);
        INSERT INTO messages VALUES (1002, 1, 2, 'Re: ', 2, 2, 1790000100, 1, 1, 0, 8);
        INSERT INTO messages VALUES (1003, 1, 3, NULL, 2, NULL, 1780000000, 1, 0, 1, 9);
        INSERT INTO messages VALUES (1004, 2, 3, NULL, 2, NULL, 1780000000, 1, 0, 0, 9);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let folder = root + "/ACC/INBOX.mbox/STORE-1/Data/1/Messages"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let body = "From: Sam <sam@example.com>\nSubject: Re: Lunch\nContent-Type: text/plain\n\nFriday works for me.\n"
        try Data(("\(body.utf8.count)\n" + body + "<plist/>").utf8).write(to: URL(fileURLWithPath: folder + "/1002.emlx"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }

    func testListsNewestFirstAndSkipsDeleted() throws {
        let boxes = try MailStore.mailboxes(root: root)
        XCTAssertEqual(boxes.map(\.name), ["INBOX", "Archive"])
        XCTAssertEqual(boxes.first?.unread, 1)
        let inbox = try MailStore.messages(root: root, .init(mailboxes: [1]))
        XCTAssertEqual(inbox.map(\.rowID), [1002, 1001])
        XCTAssertEqual(inbox.first?.subject, "Re: Lunch")
        XCTAssertEqual(inbox.first?.sender, "Sam")
        XCTAssertEqual(inbox.first?.flagged, true)
        XCTAssertEqual(inbox.last?.read, false)
        XCTAssertEqual(inbox.last?.snippet, "", "The list does not load previews.")
        XCTAssertEqual(try MailStore.messages(root: root, .init(mailboxes: [1], includePreview: true)).last?.snippet, "Your invoice is ready")
    }

    func testFiltersAndSearch() throws {
        XCTAssertEqual(try MailStore.messages(root: root, .init(mailboxes: [1], unreadOnly: true)).map(\.rowID), [1001])
        XCTAssertEqual(try MailStore.messages(root: root, .init(mailboxes: [], flaggedOnly: true)).map(\.rowID), [1002])
        XCTAssertEqual(try MailStore.messages(root: root, .init(mailboxes: [1], text: "sam lunch")).map(\.rowID), [1002])
        XCTAssertEqual(try MailStore.messages(root: root, .init(mailboxes: [1], text: "50%")).map(\.rowID), [1001], "% matches literally.")
        XCTAssertEqual(try MailStore.messages(root: root, .init(mailboxes: [1], text: "5_%")).map(\.rowID), [])
    }

    func testReadsBodyFromEMLX() throws {
        let inbox = try XCTUnwrap(try MailStore.mailboxes(root: root).first)
        let message = try XCTUnwrap(MailStore.message(root: root, mailbox: inbox, rowID: 1002))
        XCTAssertEqual(message.readableText, "Friday works for me.\n")
        XCTAssertNil(MailStore.message(root: root, mailbox: inbox, rowID: 1001), "Not downloaded.")
    }

    func testAddressesAreChecked() throws {
        XCTAssertEqual(try MailActions.addresses("Sam <sam@example.com>; ann@example.com"), ["sam@example.com", "ann@example.com"])
        XCTAssertThrowsError(try MailActions.addresses("not an address"))
        XCTAssertEqual(try MailActions.addresses(""), [])
    }

    func testHTMLDocumentImages() {
        let image = MIMEMessage.InlineImage(mimeType: "image/png", data: Data([1, 2, 3]))
        let on = MailHTMLView.document("<img src=\"cid:logo@x\"><img src=\"https://cdn.example/p.gif\">", inlineImages: ["logo@x": image], remote: true)
        XCTAssertTrue(on.contains("data:image/png;base64,AQID"), "Images inside the message are inlined.")
        XCTAssertTrue(on.contains("img-src data: http: https:"), "Web images load by default.")
        XCTAssertFalse(on.contains("script-src"), "Scripts stay blocked by default-src 'none'.")
        let off = MailHTMLView.document("<img src=\"https://cdn.example/p.gif\">", remote: false)
        XCTAssertTrue(off.contains("img-src data:;"), "With images off, only images inside the message show.")
    }
}
