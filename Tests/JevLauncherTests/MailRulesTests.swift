import XCTest
import LauncherCore

final class MailRulesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-rules-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func message(id: String = "m1", from: String = "alerts@example.com", to: [String] = ["me@example.com"],
                         subject: String = "Invoice update", account: String = "account-1") -> MailRuleMessage {
        MailRuleMessage(id: id, accountID: account, mailboxID: 1, mailboxPath: "INBOX", from: from, to: to,
                        subject: subject, receivedAt: Date(timeIntervalSince1970: 1_800_000_000), isRead: false, isFlagged: false)
    }

    func testPreviewUsesAllPredicatesAndPersistsOrder() throws {
        let store = MailRuleStore(root: root)
        let first = MailRule(name: "Invoices", predicate: MailRulePredicate(from: "alerts@", subject: "invoice", accountID: "account-1"),
                             actions: [.markRead(true)], order: 0)
        let second = MailRule(name: "Flag", predicate: MailRulePredicate(subject: "other"), actions: [.markFlagged(true)], order: 1)
        try store.saveRules([second, first])
        let rules = store.loadRules()
        XCTAssertEqual(rules.map(\.name), ["Invoices", "Flag"])
        let engine = MailRuleEngine(store: store) { _, _ in }
        XCTAssertEqual(engine.preview(rule: rules[0], messages: [message(), message(id: "m2", subject: "other")]).messageIDs, ["m1"])
    }

    func testAccountPredicateUsesExactIdentity() {
        let rule = MailRule(name: "Account", predicate: MailRulePredicate(accountID: "account-1"), actions: [.markRead(true)])
        XCTAssertTrue(rule.predicate.matches(message(account: "account-1")))
        XCTAssertFalse(rule.predicate.matches(message(account: "account-10")))
    }

    func testApplyIsOneTimeAcrossRestart() async throws {
        let store = MailRuleStore(root: root)
        let rule = MailRule(name: "Read", predicate: MailRulePredicate(from: "alerts"), actions: [.markRead(true)], updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.saveRule(rule)
        let calls = CallCounter()
        let engine = MailRuleEngine(store: store) { _, _ in calls.increment() }
        let first = await engine.apply(rule: rule, messages: [message()])
        XCTAssertEqual(first.applied.count, 1)
        XCTAssertEqual(calls.value, 1)

        let restarted = MailRuleEngine(store: MailRuleStore(root: root)) { _, _ in calls.increment() }
        let second = await restarted.apply(rule: rule, messages: [message()])
        XCTAssertEqual(second.skipped.count, 1)
        XCTAssertEqual(calls.value, 1, "A persisted applied receipt prevents a second action after restart")
    }

    func testOverlappingRulesHaveIndependentReceipts() async throws {
        let store = MailRuleStore(root: root)
        let a = MailRule(name: "From", predicate: MailRulePredicate(from: "alerts"), actions: [.markRead(true)])
        let b = MailRule(name: "Subject", predicate: MailRulePredicate(subject: "invoice"), actions: [.markFlagged(true)])
        try store.saveRules([a, b])
        let calls = CallCounter()
        let engine = MailRuleEngine(store: store) { _, _ in calls.increment() }
        let resultA = await engine.apply(rule: a, messages: [message()])
        let resultB = await engine.apply(rule: b, messages: [message()])
        XCTAssertEqual(resultA.applied.count, 1)
        XCTAssertEqual(resultB.applied.count, 1)
        XCTAssertEqual(calls.value, 2, "Each matching rule gets one durable application ID")
    }

    func testFailureAndNeedsReviewAreTerminalUntilUserChangesRule() async throws {
        let store = MailRuleStore(root: root)
        let failed = MailRule(name: "Failed", predicate: MailRulePredicate(from: "alerts"), actions: [.markRead(true)])
        let failureEngine = MailRuleEngine(store: store) { _, _ in throw TestError.failed }
        let failure = await failureEngine.apply(rule: failed, messages: [message()])
        XCTAssertEqual(failure.failed.count, 1)
        let retry = await failureEngine.apply(rule: failed, messages: [message()])
        XCTAssertEqual(retry.skipped.count, 1)

        let review = MailRule(name: "Review", predicate: MailRulePredicate(from: "alerts"), actions: [.markFlagged(true)])
        let reviewEngine = MailRuleEngine(store: store) { _, _ in throw MailRuleExecutionError.needsReview("Identity changed") }
        let needsReview = await reviewEngine.apply(rule: review, messages: [message()])
        XCTAssertEqual(needsReview.needsReview.count, 1)
        let skippedAfterReview = await reviewEngine.apply(rule: review, messages: [message()])
        XCTAssertEqual(skippedAfterReview.skipped.count, 1)
    }

    func testRunningReceiptBecomesNeedsReviewOnRestart() throws {
        let store = MailRuleStore(root: root)
        let rule = MailRule(name: "Read", predicate: MailRulePredicate(from: "alerts"), actions: [.markRead(true)])
        let application = MailRuleApplication(rule: rule, messageID: "m1", action: .markRead(true))
        try store.saveApplications([application.id: application])
        XCTAssertEqual(try store.recoverRunningApplications(), 1)
        XCTAssertEqual(store.loadApplications()[application.id]?.state, .needsReview)
    }

    func testCorruptRulesRefuseMutationAndPreserveBytes() throws {
        let store = MailRuleStore(root: root)
        let original = Data("not-json".utf8)
        try original.write(to: store.rulesURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.rulesURL.path)
        XCTAssertTrue(store.loadRules().isEmpty)
        XCTAssertNotNil(store.rulesError)
        XCTAssertThrowsError(try store.saveRules([]))
        XCTAssertEqual(try Data(contentsOf: store.rulesURL), original)
    }

    func testNonOwnerOnlyRulesRefuseMutationAndPreserveBytes() throws {
        let store = MailRuleStore(root: root)
        let original = Data("[]".utf8)
        try original.write(to: store.rulesURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.rulesURL.path)
        XCTAssertTrue(store.loadRules().isEmpty)
        XCTAssertNotNil(store.rulesError)
        XCTAssertThrowsError(try store.saveRules([]))
        XCTAssertEqual(try Data(contentsOf: store.rulesURL), original)
    }

    func testSymlinkedApplicationHistoryRefusesMutation() throws {
        let store = MailRuleStore(root: root)
        let target = root.appendingPathComponent("outside.json")
        let original = Data("{}".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: store.applicationsURL, withDestinationURL: target)
        XCTAssertTrue(store.loadApplications().isEmpty)
        XCTAssertNotNil(store.applicationsError)
        XCTAssertThrowsError(try store.saveApplications([:]))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private enum TestError: Error { case failed }
}
