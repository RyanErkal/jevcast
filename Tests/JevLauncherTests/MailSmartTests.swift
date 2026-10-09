import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailSmartTests: XCTestCase {
    func testPreviewExposesMatchesAndOpenCallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smart-controller-" + UUID().uuidString)
        let smartURL = root.appendingPathComponent("smart.json")
        let ruleRoot = root.appendingPathComponent("rules", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var opened: [String] = []
        let observed = MailRuleMessage(id: "m1", accountID: "acc", mailboxID: 1, mailboxPath: "INBOX", from: "vip@example.com",
                                       subject: "Invoice", receivedAt: Date(), isRead: false, isFlagged: false)
        let controller = MailSmartController(store: MailSmartStore(url: smartURL), rules: MailRuleStore(root: ruleRoot),
                                              observeMessages: { [observed] }, openMessage: { opened.append($0) })
        let mailbox = MailSmartMailbox(name: "Invoices", predicate: MailRulePredicate(subject: "invoice"))
        controller.saveMailbox(mailbox)
        controller.preview(mailbox)
        XCTAssertEqual(controller.previewMessages.map(\.id), ["m1"])
        controller.open(messageID: "m1")
        XCTAssertEqual(opened, ["m1"])
        try? FileManager.default.removeItem(at: root)
    }

    func testUnblockRemovesOnlyTheRecordedGeneratedRule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smart-unblock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let smart = MailSmartStore(url: root.appendingPathComponent("smart.json"))
        let rules = MailRuleStore(root: root.appendingPathComponent("rules", isDirectory: true))
        let controller = MailSmartController(store: smart, rules: rules, junkFolder: { _ in MailJunkFolderIdentity(accountID: "acc", mailboxID: 9, path: "Junk") })
        controller.blockSender("spam@example.com", accountID: "acc")
        XCTAssertEqual(rules.loadRules().count, 1)
        controller.unblockSender("spam@example.com")
        XCTAssertTrue(rules.loadRules().isEmpty)
        XCTAssertTrue(smart.load().blockedSenders.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    func testUnblockDoesNotDeleteChangedRuleWithRecordedID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smart-unblock-changed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let smart = MailSmartStore(url: root.appendingPathComponent("smart.json"))
        let rules = MailRuleStore(root: root.appendingPathComponent("rules", isDirectory: true))
        let controller = MailSmartController(store: smart, rules: rules,
                                             junkFolder: { _ in MailJunkFolderIdentity(accountID: "acc", mailboxID: 9, path: "Junk") })
        controller.blockSender("spam@example.com", accountID: "acc")
        guard var changed = rules.loadRules().first else { return XCTFail("Expected generated rule") }
        changed.name = "A user-edited rule"
        try rules.saveRule(changed)

        controller.unblockSender("spam@example.com")
        XCTAssertEqual(rules.loadRules().map(\.id), [changed.id])
        XCTAssertTrue(smart.load().blockedSenders.contains("spam@example.com"))
        try? FileManager.default.removeItem(at: root)
    }
}
