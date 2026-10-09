import Foundation
import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailDraftImportTests: XCTestCase {
    func testImportKeepsIdentityThreadingRecipientsAndAttachments() throws {
        let raw = Data("""
        From: Alias <alias@example.com>
        To: Sam <sam@example.com>
        Cc: Team <team@example.com>
        Bcc: Hidden <hidden@example.com>
        Subject: Plans
        Message-ID: <draft@example.com>
        In-Reply-To: <original@example.com>
        References: <thread@example.com> <original@example.com>
        Content-Type: multipart/mixed; boundary="parts"

        --parts
        Content-Type: text/plain; charset=utf-8

        Hello
        --parts
        Content-Type: application/octet-stream; name="plan.txt"
        Content-Disposition: attachment; filename="plan.txt"
        Content-Transfer-Encoding: base64

        cGxhbg==
        --parts--
        """.utf8)
        let message = try XCTUnwrap(MIMEMessage.parse(raw))
        let reference = MailServerDraftReference(accountID: "account", mailboxID: 7, uidValidity: 1, uid: 4,
                                                 messageID: "<draft@example.com>", digest: String(repeating: "a", count: 64))
        let identity = MailSendingIdentity(accountID: "account", address: "alias@example.com", name: "Alias",
                                           signature: "Cheers", accountAddress: "me@example.com",
                                           providerAuthorized: true)
        let draft = MailDraftImportBuilder.build(raw: raw, message: message, reference: reference,
                                                  identity: identity, senders: [identity])
        XCTAssertEqual(draft.fromIdentityID, identity.id)
        XCTAssertEqual(draft.fromAddress, "alias@example.com")
        XCTAssertEqual(draft.to, "Sam <sam@example.com>")
        XCTAssertEqual(draft.bcc, "Hidden <hidden@example.com>")
        XCTAssertEqual(draft.serverDraftInReplyTo, "<original@example.com>")
        XCTAssertEqual(draft.serverDraftReferences, ["<thread@example.com>", "<original@example.com>"])
        XCTAssertTrue(draft.serverDraftImported == true)
        XCTAssertEqual(draft.attachments.last?.data, Data("plan".utf8))
    }

    func testImportedDraftIsNotWritableUntilItsFieldsChange() {
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "account",
                                    fromAddress: "me@example.com", to: "sam@example.com", body: "Hello")
        draft.serverDraftImported = true
        XCTAssertEqual(draft.fields, draft.fields)
        XCTAssertTrue(draft.serverDraftImported == true)
        draft.body = "Edited locally"
        XCTAssertNotEqual(draft.body, "Hello")
    }

    func testImportedDraftDoesNotAutosaveUntilEdited() async throws {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, draftStore: nil)
        model.senders = [.init(accountID: "account", address: "me@example.com", name: "Me", signature: "")]
        var saves = 0
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
            saves += 1
            return .init(accountID: "account", mailboxID: 3, uidValidity: 1, uid: UInt32(saves),
                         messageID: "<draft\(saves)@example.com>", digest: String(repeating: "a", count: 64))
        }, remove: { _ in }, debounceNanoseconds: 1_000_000)
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "account",
                                    fromAddress: "me@example.com", to: "sam@example.com", body: "Remote")
        draft.serverDraftImported = true
        draft.serverDraftReference = .init(accountID: "account", mailboxID: 3, uidValidity: 1, uid: 8,
                                           messageID: "<remote@example.com>", digest: String(repeating: "b", count: 64))
        model.draft = draft
        coordinator.changed(draft)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(saves, 0)
        draft.body = "Edited"
        model.draft = draft
        coordinator.changed(draft)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(saves, 1)
    }
}
