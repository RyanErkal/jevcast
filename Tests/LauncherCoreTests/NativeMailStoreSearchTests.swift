import XCTest
@testable import LauncherCore

final class NativeMailStoreSearchTests: XCTestCase {
    private var root: URL!
    private var store: NativeMailStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-index-" + UUID().uuidString, isDirectory: true)
        store = try NativeMailStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        store = nil
    }

    func testCatalogKeepsSelectableVirtualMailboxesAndReportsCompletion() async throws {
        let entries = [
            IMAPListEntry(flags: [], delimiter: "/", rawName: "INBOX"),
            IMAPListEntry(flags: ["\\Flagged"], delimiter: "/", rawName: "Starred"),
            IMAPListEntry(flags: ["\\Important"], delimiter: "/", rawName: "Important"),
            IMAPListEntry(flags: ["\\All"], delimiter: "/", rawName: "All Mail"),
            IMAPListEntry(flags: ["\\Noselect"], delimiter: "/", rawName: "Groups")
        ]
        let boxes = try await store.replaceMailboxes(account: "acct-1", with: entries)
        XCTAssertEqual(boxes.map(\.name), ["INBOX", "All Mail", "Important", "Starred"])

        try await store.setServerCounts([boxes[0].rowID: (total: 9, unread: 4)])
        let inboxValue = try await store.mailbox(boxes[0].rowID)
        let inbox = try XCTUnwrap(inboxValue)
        XCTAssertEqual(inbox.downloadedCount, 0)
        XCTAssertEqual(inbox.serverTotal, 9)
        XCTAssertEqual(inbox.serverUnread, 4)
        XCTAssertFalse(inbox.complete)
    }

    func testFTSUpdatesForHeadersBodiesAndRemovalsAndDedupesCopies() async throws {
        let boxes = try await store.replaceMailboxes(account: "acct-1", with: [
            IMAPListEntry(flags: [], delimiter: "/", rawName: "INBOX"),
            IMAPListEntry(flags: ["\\All"], delimiter: "/", rawName: "All Mail")
        ])
        let inbox = try XCTUnwrap(boxes.first { $0.name == "INBOX" })
        let all = try XCTUnwrap(boxes.first { $0.name == "All Mail" })

        var first = SyncedMessage(uid: 1, date: Date(timeIntervalSince1970: 100))
        first.subject = "Quarterly planning"
        first.senderName = "Sam"
        first.senderAddress = "sam@example.com"
        first.messageKey = SyncedMessage.hash("<same@example.com>")
        try await store.upsert([first], into: inbox.rowID)
        var copy = first
        copy.uid = 2
        try await store.upsert([copy], into: all.rowID)

        let headerRows = try await store.search(mailboxIDs: [inbox.rowID, all.rowID], text: "quarterly", preferredMailboxIDs: [inbox.rowID])
        let headerValue = try await store.rowID(uid: 1, in: inbox.rowID)
        let headerRow = try XCTUnwrap(headerValue)
        XCTAssertEqual(headerRows.rowIDs, [headerRow])

        let rowID = headerRow
        let raw = Data("From: Sam <sam@example.com>\r\nSubject: Quarterly planning\r\n\r\nPrivate roadmap phrase".utf8)
        try await store.saveBody(rowID, raw: raw)
        let bodyMatches = try await store.searchIndexed(mailboxIDs: [inbox.rowID], text: "roadmap phrase")
        XCTAssertEqual(bodyMatches, [rowID])

        try await store.remove(uids: [1], from: inbox.rowID)
        let removedMatches = try await store.searchIndexed(mailboxIDs: [inbox.rowID], text: "quarterly")
        XCTAssertTrue(removedMatches.isEmpty)
    }

    func testIndexedSearchCompletionSeesDistinctMatchBeyondPageLimit() async throws {
        let boxes = try await store.replaceMailboxes(account: "acct-1", with: [
            IMAPListEntry(flags: [], delimiter: "/", rawName: "INBOX")
        ])
        let inbox = try XCTUnwrap(boxes.first)
        var first = SyncedMessage(uid: 1, date: Date(timeIntervalSince1970: 100))
        first.subject = "Quarterly planning"
        first.senderAddress = "one@example.com"
        var second = first
        second.uid = 2
        second.senderAddress = "two@example.com"
        try await store.upsert([first, second], into: inbox.rowID)

        let page = try await store.search(mailboxIDs: [inbox.rowID], text: "quarterly", limit: 1)
        XCTAssertEqual(page.rowIDs.count, 1)
        XCTAssertFalse(page.complete, "A second distinct match exists beyond the requested page")

        let exhausted = try await store.search(mailboxIDs: [inbox.rowID], text: "quarterly", limit: 3)
        XCTAssertEqual(exhausted.rowIDs.count, 2)
        XCTAssertTrue(exhausted.complete)
    }
}
