import XCTest
@testable import LauncherCore

final class MailOrganizationTests: XCTestCase {
    private func summary(_ id: Int64, account: Int64 = 1, subject: String = "Same subject", read: Bool = true,
                         flagged: Bool = false, date: TimeInterval = 100) -> MailSummary {
        MailSummary(rowID: id, mailbox: account, subject: subject, senderName: "Sender", senderAddress: "sender\(id)@example.com",
                    snippet: "", date: Date(timeIntervalSince1970: date + Double(id)), read: read,
                    flagged: flagged, conversation: id)
    }

    func testProviderThreadsAreAccountScopedAndSubjectDoesNotGroup() {
        let one = MailConversationMessage(summary: summary(1), accountID: "a", header: .init(providerThreadID: 42, messageID: "<one@a>"))
        let two = MailConversationMessage(summary: summary(2), accountID: "a", header: .init(providerThreadID: 42, messageID: "<two@a>"))
        let otherAccount = MailConversationMessage(summary: summary(3, account: 2), accountID: "b", header: .init(providerThreadID: 42, messageID: "<three@b>"))
        let unrelated = MailConversationMessage(summary: summary(4), accountID: "a", header: .init(messageID: "<four@a>"))
        let groups = MailConversationGrouping.group([one, two, otherAccount, unrelated])
        XCTAssertEqual(groups.map(\.messages.count).sorted(), [1, 1, 2])
        XCTAssertEqual(groups.first { $0.accountID == "a" && $0.messages.count == 2 }?.subject, "Same subject")
    }

    func testReferencesBuildAThreadWithoutSubjectMatching() {
        let parent = MailConversationMessage(summary: summary(1), accountID: "a", header: .init(messageID: "<parent@a>"))
        let reply = MailConversationMessage(summary: summary(2, subject: "Different subject"), accountID: "a",
                                            header: .init(messageID: "<reply@a>", inReplyTo: "<parent@a>"))
        let unrelated = MailConversationMessage(summary: summary(3), accountID: "a", header: .init(messageID: "<other@a>"))
        let groups = MailConversationGrouping.group([parent, reply, unrelated])
        XCTAssertEqual(groups.map(\.messages.count).sorted(), [1, 2])
        XCTAssertEqual(groups.first { $0.messages.count == 2 }?.messages.map { $0.summary.rowID }, [2, 1])
    }

    func testProviderThreadWinsOverConflictingReferences() {
        let first = MailConversationMessage(summary: summary(1), accountID: "a",
                                            header: .init(providerThreadID: 1, messageID: "<one@a>", references: ["<root@a>"]))
        let second = MailConversationMessage(summary: summary(2), accountID: "a",
                                             header: .init(providerThreadID: 2, messageID: "<two@a>", references: ["<root@a>"]))
        XCTAssertEqual(MailConversationGrouping.group([first, second]).map(\.messages.count), [1, 1])
    }

    func testHeaderPoorBridgeCannotMixTwoProviderThreads() {
        let first = MailConversationMessage(summary: summary(1), accountID: "a",
                                            header: .init(providerThreadID: 1, messageID: "<one@a>", references: ["<root@a>"]))
        let bridge = MailConversationMessage(summary: summary(2), accountID: "a",
                                             header: .init(messageID: "<bridge@a>", references: ["<root@a>", "<other-root@a>"]))
        let second = MailConversationMessage(summary: summary(3), accountID: "a",
                                             header: .init(providerThreadID: 2, messageID: "<two@a>", references: ["<other-root@a>"]))
        let groups = MailConversationGrouping.group([first, bridge, second])
        XCTAssertEqual(groups.map(\.messages.count).sorted(), [1, 1, 1])
    }

    func testUnknownAccountRowsNeverShareAThreadScope() {
        let first = MailConversationMessage(summary: summary(1), accountID: "",
                                            header: .init(providerThreadID: 7, messageID: "<one@example>"))
        let second = MailConversationMessage(summary: summary(2), accountID: "",
                                             header: .init(providerThreadID: 7, messageID: "<two@example>"))
        XCTAssertEqual(MailConversationGrouping.group([first, second]).map(\.messages.count).sorted(), [1, 1])
    }

    func testStructuredFiltersRunBeforePagination() {
        let messages = (1...5).map { summary(Int64($0), read: $0 % 2 == 0, date: Double($0)) }
        let filter = MailFilter(unreadOnly: true)
        let page = MailFilterPaging.page(messages, filter: filter, offset: 0, limit: 10)
        XCTAssertEqual(page.map(\.rowID), [5, 3, 1])
        let metadata = Dictionary(uniqueKeysWithValues: messages.map { ($0.rowID, MailFilterMessageMetadata(accountID: $0.rowID == 1 ? "work" : "home")) })
        let account = MailFilter(accountIDs: ["work"])
        XCTAssertEqual(MailFilterPaging.filter(messages, by: account, metadata: metadata).map(\.rowID), [1])
    }

    func testBodyDependentFiltersDoNotTreatUnknownAsNoAttachmentOrRecipient() {
        let message = summary(1)
        let unknown = MailFilterMessageMetadata(accountID: "work", recipientsKnown: false, attachmentsKnown: false)
        XCTAssertFalse(MailFilter(attachmentsOnly: true).matches(message, metadata: unknown))
        XCTAssertFalse(MailFilter(to: "person@example.com").matches(message, metadata: unknown))
        XCTAssertTrue(MailFilter(to: "person@example.com").requiresBodyMetadata)
    }

    func testUnknownCoverageOnlyCountsRowsThatCouldMatchIndexedPredicates() {
        let candidate = summary(1, account: 1, read: false, date: 100)
        let excluded = summary(2, account: 1, read: true, date: 100)
        let filter = MailFilter(accountIDs: ["work"], to: "person@example.com", unreadOnly: true)
        let candidateMetadata = MailFilterMessageMetadata(accountID: "work", recipientsKnown: false, attachmentsKnown: false)
        let excludedMetadata = MailFilterMessageMetadata(accountID: "other", recipientsKnown: false, attachmentsKnown: false)
        XCTAssertTrue(filter.matchesIndexedFields(candidate, metadata: candidateMetadata))
        XCTAssertFalse(filter.matchesIndexedFields(excluded, metadata: excludedMetadata))
        XCTAssertEqual(filter.bodyMetadataCoverageDescription, "The To filter matches downloaded message bodies only.")
    }

    func testBulkSnapshotsAreExactAndNeverPermanentDelete() {
        let message = summary(9, read: false, flagged: true)
        let snapshot = MailBulkSnapshot(message: message, sourceMailboxID: 1, accountID: "a", expectedMessageID: "<nine@a>")
        let result = MailBulkResult(operation: .trash, reviewed: [snapshot], succeeded: [snapshot], undoable: [snapshot])
        XCTAssertEqual(result.undoable, [snapshot])
        XCTAssertEqual(result.operation, .trash)
    }
}
