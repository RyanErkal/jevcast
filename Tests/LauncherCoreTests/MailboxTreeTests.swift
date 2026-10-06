import XCTest
@testable import LauncherCore

final class MailboxTreeTests: XCTestCase {
    func testFoldersKeepParentsSelectionAndSeparateAccounts() {
        let parent = MailMailbox(rowID: 1, url: "imap://work/Clients", unread: 0, total: 0)
        let child = MailMailbox(rowID: 2, url: "imap://work/Clients/Acme", unread: 3, total: 8)
        let personal = MailMailbox(rowID: 3, url: "imap://personal/Clients/Acme", unread: 1, total: 2)
        let tree = MailboxTree.build([child, parent, personal])
        XCTAssertEqual(tree.count, 2)
        let work = tree.first { $0.accountID == "work" }
        XCTAssertEqual(work?.mailbox?.rowID, 1)
        XCTAssertEqual(work?.children.first?.mailbox?.rowID, 2)
        XCTAssertEqual(tree.first { $0.accountID == "personal" }?.children.first?.mailbox?.rowID, 3)
    }

    func testEncodedSlashIsOneFolderNameAndDoesNotMergeWithHierarchy() {
        let literal = MailMailbox(rowID: 1, url: "imap://work/Clients%2FAcme", unread: 0, total: 1)
        let nested = MailMailbox(rowID: 2, url: "imap://work/Clients/Acme", unread: 0, total: 1)
        let tree = MailboxTree.build([literal, nested])
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(literal.name, "Clients/Acme")
        XCTAssertTrue(tree.contains { $0.title == "Clients/Acme" && $0.mailbox?.rowID == 1 })
        XCTAssertTrue(tree.contains { $0.title == "Clients" && $0.children.first?.mailbox?.rowID == 2 })
        XCTAssertEqual(Set(tree.map(\.id)).count, 2)
        XCTAssertEqual(literal.folder(in: "/tmp/mail"), "/tmp/mail/work/Clients%2FAcme.mbox")
        XCTAssertEqual(nested.folder(in: "/tmp/mail"), "/tmp/mail/work/Clients.mbox/Acme.mbox")
        let percent = MailMailbox(rowID: 3, url: "imap://work/Clients%252FAcme", unread: 0, total: 0)
        XCTAssertNotEqual(literal.folder(in: "/tmp/mail"), percent.folder(in: "/tmp/mail"))
    }
}
