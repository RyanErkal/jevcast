import Foundation
import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailWorkspaceTests: XCTestCase {
    func testUnifiedScopesIncludeSentDraftsAndUnreadOutsideInbox() {
        let roles: [MailMailbox.Role] = [.inbox, .sent, .drafts, .archive, .other, .trash, .junk]
        let boxes = roles.enumerated().map { offset, role in
            MailMailbox(rowID: Int64(offset + 1), url: "imap://demo/\(role.rawValue)", unread: 1, total: 2, serverRole: role)
        }
        XCTAssertEqual(MailModel.query(.allMail, "", boxes).mailboxes, [1, 2, 3, 4, 5])
        XCTAssertEqual(MailModel.query(.unread, "", boxes).mailboxes, [1, 2, 3, 4, 5])
        XCTAssertTrue(MailModel.query(.unread, "", boxes).unreadOnly)
        XCTAssertEqual(MailModel.query(.drafts, "", boxes).mailboxes, [3])
        XCTAssertEqual(MailModel.query(.sent, "", boxes).mailboxes, [2])
    }

    func testAcceptedSubmissionCannotBeRestoredForResend() {
        let model = fixture()
        let draft = preparedDraft()
        let receipt = MailSendReceipt(accountID: "demo", messageID: draft.sendingMessageID,
                                      sentCopy: .pending, message: Data("saved bytes".utf8), date: Date())
        model.recordSubmission(draft, .serverAccepted(receipt))
        XCTAssertEqual(model.deliveries.first?.state, .sentCopyPending)
        XCTAssertNil(model.deliveries.first?.draft)
        model.restoreDelivery(model.deliveries[0], allowResend: true)
        XCTAssertNil(model.draft)
        model.recordSubmission(draft, .appleMailQueued)
        XCTAssertEqual(model.deliveries.first?.state, .appleMailQueued)
        XCTAssertNil(model.deliveries.first?.draft)
    }

    func testPendingSentReceiptSurvivesRestartWithoutResend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-receipt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MailDraftStore(directory: directory), model = fixture(store: store)
        let draft = preparedDraft()
        let raw = MailComposer.render(OutgoingMessage(from: .init(address: "alex@example.com"), to: [.init(address: "sam@example.com")], subject: "Test", body: "Hello"))
        let receipt = MailSendReceipt(accountID: "demo", messageID: draft.sendingMessageID, sentCopy: .pending, message: raw, date: Date())
        model.recordSubmission(draft, .serverAccepted(receipt))
        try await model.saveCompositionAsync()
        let loaded = try store.load()
        XCTAssertNil(loaded.active)
        XCTAssertTrue(loaded.unsent.isEmpty)
        XCTAssertEqual(loaded.deliveries.first?.receipt?.message, raw)
        XCTAssertEqual(loaded.deliveries.first?.state, .sentCopyPending)
    }

    func testFailedQueuedCheckpointNeverCallsTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-checkpoint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MailDraftStore(directory: directory)
        var calls = 0
        let model = fixture(store: store, send: { _, _ in calls += 1 })
        model.draft = preparedDraft()
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("composition.json"))
        XCTAssertNil(model.send())
        await model.finishSends()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.deliveries.first?.state, .failed)
        XCTAssertEqual(model.draft?.body, "Hello")
    }

    func testUndoBeforeQueuedCheckpointNeverCallsTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-undo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let model = fixture(store: MailDraftStore(directory: directory), delay: 60, send: { _, _ in calls += 1 })
        model.draft = preparedDraft()
        XCTAssertNil(model.send())
        model.undoSend()
        await model.finishSends()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.deliveries.first?.state, .undone)
        XCTAssertEqual(model.draft?.body, "Hello")
        XCTAssertEqual(model.sendsInFlight, 0)
    }

    func testNativeRecipientValidationMatchesSMTP() {
        var draft = preparedDraft()
        draft.backend = MailBackend.jevcast.rawValue
        draft.to = "säm@example.com"
        XCTAssertNotNil(draft.sendProblem)
        XCTAssertFalse(SMTPClient.isSafeAddress("säm@example.com"))
        draft.to = "Sam <sam@example.com>"
        XCTAssertNil(draft.sendProblem)
    }

    func testComposeFromInlineOutboxShowsTheDraft() {
        let model = fixture()
        model.place = .outbox
        model.compose(to: "sam@example.com")
        XCTAssertEqual(model.place, .drafts)
        XCTAssertEqual(model.draft?.to, "sam@example.com")
    }

    private func preparedDraft() -> MailModel.Draft {
        .init(backend: MailBackend.current.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com", to: "sam@example.com", subject: "Test", body: "Hello")
    }
    private func fixture(store: MailDraftStore? = nil, delay: TimeInterval = 0,
                         send: @escaping (MailModel.Draft, MailMailbox?) async throws -> Void = { _, _ in }) -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              statusProvider: { .noMail }, sendDraft: send, undoDelay: delay, draftStore: store, mailDefaults: nil)
        model.senders = [.init(accountID: "demo", address: "alex@example.com", name: "Alex", signature: "")]
        return model
    }
}
