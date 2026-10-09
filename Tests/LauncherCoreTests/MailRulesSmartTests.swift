import XCTest
@testable import LauncherCore

final class MailRulesSmartTests: XCTestCase {
    private var url: URL!
    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("mail-smart-" + UUID().uuidString + ".json")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: url) }

    func testSavedMailboxAndVIPPersistAcrossRestart() throws {
        let store = MailSmartStore(url: url)
        let mailbox = MailSmartMailbox(name: "Invoices", predicate: MailRulePredicate(subject: "invoice"))
        try store.saveMailbox(mailbox)
        try store.setVIP("  VIP@Example.com ", enabled: true)
        let restarted = MailSmartStore(url: url)
        XCTAssertEqual(restarted.load().mailboxes, [mailbox])
        XCTAssertEqual(restarted.load().vipAddresses, ["vip@example.com"])
        XCTAssertTrue(mailbox.matches(MailRuleMessage(id: "m", accountID: "a", mailboxID: 1, mailboxPath: "INBOX", from: "x@y.example",
                                                       subject: "Invoice ready", receivedAt: Date(), isRead: false, isFlagged: false)))
    }

    func testBlockingSenderCreatesJunkRuleWithExplicitIdentity() throws {
        let store = MailSmartStore(url: url)
        let rule = try store.blockSender("Spam@Example.com", accountID: "acc", junkMailboxID: 42, junkPath: "Junk")
        XCTAssertEqual(rule.predicate.from, "spam@example.com")
        XCTAssertEqual(rule.actions, [.moveToFolder(accountID: "acc", mailboxID: 42, path: "Junk")])
        XCTAssertEqual(store.load().blockedSenders, ["spam@example.com"])
        XCTAssertEqual(store.load().blockedRuleIDs["spam@example.com"], rule.id)
        try store.removeBlockedSender("spam@example.com")
        XCTAssertTrue(store.load().blockedSenders.isEmpty)
    }

    func testCorruptSmartStateRefusesMutationAndPreservesBytes() throws {
        let original = Data("broken".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = MailSmartStore(url: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.save(MailSmartState()))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testNonOwnerOnlySmartStateRefusesMutationAndPreservesBytes() throws {
        let original = Data("{}".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let store = MailSmartStore(url: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.save(MailSmartState()))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSymlinkedSmartStateRefusesMutation() throws {
        let target = url.deletingLastPathComponent().appendingPathComponent("smart-outside.json")
        let original = Data("{}".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = MailSmartStore(url: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.save(MailSmartState()))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
