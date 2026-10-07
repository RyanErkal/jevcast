import XCTest
import LauncherCore
@testable import JevLauncher

final class MailSidebarPresentationTests: XCTestCase {
    func testPrimaryFoldersAreFlatAndEveryMailboxRemainsReachableOnce() {
        let boxes = [box(1, "INBOX", .inbox), box(2, "[Gmail]/Drafts", .drafts),
                     box(3, "[Gmail]/Sent Mail", .sent), box(4, "[Gmail]/All Mail", .archive),
                     box(5, "[Gmail]/Trash", .trash), box(6, "[Gmail]/Spam", .junk),
                     box(7, "[Gmail]/Important"), box(8, "Clients"), box(9, "Clients/Acme")]
        let layout = MailSidebarFolders(boxes)
        XCTAssertEqual(layout.primary.compactMap { $0.mailbox?.rowID }, [1, 2, 3, 4, 5])
        XCTAssertEqual(layout.primary.map(layout.title), ["Inbox", "Drafts", "Sent", "All Mail", "Trash"])
        XCTAssertEqual(layout.providerFolders.map(\.title), ["[Gmail]"])
        XCTAssertEqual(layout.folders.map(\.title), ["Clients"])
        XCTAssertEqual(ids(layout).sorted(), boxes.map(\.rowID).sorted())
    }

    func testPromotedMailboxKeepsItsCompleteSubtree() {
        let boxes = [box(1, "Saved", .archive), box(2, "Saved/Archive", .archive), box(3, "Saved/Archive/Receipts")]
        let layout = MailSidebarFolders(boxes)
        XCTAssertEqual(layout.primary.count, 1)
        XCTAssertEqual(layout.primary[0].children[0].mailbox?.rowID, 2)
        XCTAssertEqual(ids(layout).sorted(), [1, 2, 3])
        XCTAssertTrue(layout.folders.isEmpty)
    }

    func testDuplicateRolesAndNamesUseDistinctPathsAndIdentities() {
        let layout = MailSidebarFolders([box(1, "Sent", .sent), box(2, "Old/Sent", .sent), box(3, "[Gmail]/Sent", .sent)])
        XCTAssertEqual(Set(layout.primary.map(layout.title)), ["Sent", "Old/Sent", "[Gmail]/Sent"])
        XCTAssertEqual(ids(layout).sorted(), [1, 2, 3])
    }

    func testProviderRootWithRealMailboxIsPreserved() {
        let layout = MailSidebarFolders([box(1, "[Google Mail]"), box(2, "[Google Mail]/Drafts", .drafts),
                                         box(3, "[Google Mail]/Important")])
        XCTAssertEqual(layout.providerFolders.first?.mailbox?.rowID, 1)
        XCTAssertEqual(layout.providerFolders.first?.children.first?.mailbox?.rowID, 3)
        XCTAssertEqual(ids(layout).sorted(), [1, 2, 3])
    }

    func testEncodedSlashDoesNotBecomeHierarchy() {
        let layout = MailSidebarFolders([box(1, "Clients%2FAcme"), box(2, "Clients/Acme")])
        XCTAssertEqual(layout.folders.count, 2)
        let literal = layout.folders.first { $0.mailbox?.rowID == 1 }
        XCTAssertEqual(literal?.title, "Clients/Acme")
        XCTAssertTrue(literal?.children.isEmpty == true)
        XCTAssertEqual(ids(layout).sorted(), [1, 2])
    }

    func testAccountLabelsAreShortAndDoNotUseSenderNames() {
        let labels = MailSidebarAccounts.labels([(id: "a", address: "alex@gmail.com"), (id: "b", address: "alex@acme.example")])
        XCTAssertEqual(labels, ["a": "Alex", "b": "Acme"])
    }

    func testAccountCollisionsAndUnknownAccountsStayDistinct() {
        let uuid = "B88D65AC-548D-48EB-86FD-123456789ABC"
        let labels = MailSidebarAccounts.labels([(id: "a", address: "alex@gmail.com"), (id: "b", address: "alex@icloud.com"),
                                                 (id: "c", address: "alex@gmail.com"), (id: "", address: ""), (id: uuid, address: uuid)])
        XCTAssertEqual(labels["a"], "alex@gmail.com (1)")
        XCTAssertEqual(labels["b"], "alex@icloud.com")
        XCTAssertEqual(labels["c"], "alex@gmail.com (2)")
        XCTAssertEqual(labels[""], "On My Mac")
        XCTAssertEqual(labels[uuid], "Account 9ABC")
        XCTAssertEqual(Set(labels.values).count, labels.count)
    }

    @MainActor
    func testProviderDisclosureStartsCollapsedAndPersistsSeparately() throws {
        let suite = "mail-sidebar-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func model() -> MailModel {
            MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                      statusProvider: { .noMail }, draftStore: nil, mailDefaults: defaults)
        }
        let first = model()
        XCTAssertTrue(first.expandedSidebarGroupKeys.isEmpty)
        first.setMailboxExpanded("account:demo", false)
        first.setSidebarGroupExpanded("demo:[Gmail]", true)
        let restored = model()
        XCTAssertEqual(restored.expandedSidebarGroupKeys, ["demo:[Gmail]"])
        XCTAssertEqual(restored.collapsedMailboxKeys, ["account:demo"])
        restored.setSidebarGroupExpanded("demo:[Gmail]", false)
        XCTAssertTrue(model().expandedSidebarGroupKeys.isEmpty)
    }

    private func box(_ id: Int64, _ path: String, _ role: MailMailbox.Role = .other) -> MailMailbox {
        MailMailbox(rowID: id, url: "imap://demo/" + path, unread: 0, total: 0, serverRole: role)
    }
    private func ids(_ layout: MailSidebarFolders) -> [Int64] {
        func walk(_ nodes: [MailboxTree]) -> [Int64] {
            nodes.flatMap { node in (node.mailbox.map { [$0.rowID] } ?? []) + walk(node.children) }
        }
        return walk(layout.primary + layout.providerFolders + layout.folders)
    }
}
