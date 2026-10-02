import AppKit
import LauncherCore
import XCTest
@testable import JevLauncher

@MainActor
final class MailPersistenceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-drafts-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testDraftRoundTripKeepsSenderFormattingAndImmutableAttachmentBytes() throws {
        var draft = MailModel.Draft(fromAccountID: "fixture", fromAddress: "me@example.com", mode: .new,
                                    to: "sam@example.com", subject: "Saved", body: "Styled")
        let text = NSAttributedString(string: "Styled", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        draft.richText = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        draft.attachments = [.init(filename: "chosen.txt", mimeType: "text/plain", data: Data("Chosen bytes".utf8))]
        let store = MailDraftStore(directory: directory)
        try store.save(.init(active: draft))
        let restored = try XCTUnwrap(store.load().active)
        XCTAssertEqual(restored, draft)
        XCTAssertTrue(MailRichText.html(restored.richText, plain: restored.body).contains("font-weight:bold"))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("composition.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRestartNeverResumesQueuedOrInterruptedSends() throws {
        let queued = MailModel.Draft(to: "sam@example.com", body: "Queued")
        let sending = MailModel.Draft(to: "sam@example.com", body: "Interrupted")
        let deliveries = [queued, sending].enumerated().map { offset, draft in
            MailDelivery(id: draft.id, draft: draft, subject: draft.subject, recipient: draft.to, date: Date(), state: offset == 0 ? .queued : .sending)
        }
        let store = MailDraftStore(directory: directory)
        try store.save(.init(active: sending, deliveries: deliveries))
        let snapshot = try store.load()
        XCTAssertEqual(snapshot.deliveries.map(\.state), [.failed, .uncertain])
        XCTAssertEqual(snapshot.unsent.count, 1)
        XCTAssertEqual(snapshot.unsent.first?.id, queued.id)
        XCTAssertEqual(snapshot.active?.uncertainSend, true)
        XCTAssertFalse(snapshot.active?.canSend ?? true)
        var attempts = 0
        let model = MailModel(quill: { _ in throw CancellationError() }, quillAllowed: { false },
                              sendDraft: { _, _ in attempts += 1 }, undoDelay: 0, draftStore: store)
        XCTAssertFalse(model.sending)
        XCTAssertNil(model.pendingSend)
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(model.draft?.uncertainSend == true)
    }

    func testUnreadablePersistenceBlocksSendingAndDoesNotOverwriteData() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("composition.json"), bytes = Data("unreadable fixture".utf8)
        try bytes.write(to: file)
        var attempts = 0
        let model = MailModel(quill: { _ in throw CancellationError() }, quillAllowed: { false },
                              sendDraft: { _, _ in attempts += 1 }, undoDelay: 0, draftStore: MailDraftStore(directory: directory))
        model.senders = [.init(accountID: "fixture", address: "me@example.com", name: "Me", signature: "")]
        model.compose(to: "sam@example.com"); model.draft?.body = "Do not send"
        XCTAssertNotNil(model.send())
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testStoreRefusesSymlink() throws {
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try MailDraftStore(directory: directory).save(.init()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testAttachmentsAreReadOnceAndOnlyChosenBytesAreStaged() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("chosen.txt")
        try Data("Initial contents".utf8).write(to: file)
        let attachment = try MailComposeAttachments.read(file, inline: false)
        try Data("Later contents".utf8).write(to: file)
        let staged = try MailAttachmentStaging([attachment])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staged.paths[0])), Data("Initial contents".utf8))
        XCTAssertFalse(staged.paths.contains(file.path))
    }

    func testSenderListRejectsMalformedRowsAndRemovesDuplicates() {
        let identities = MailSendingIdentity.parse("a\tme@example.com\tMe\na\tme@example.com\tMe\nb\tbad address\tX\nwrong-row")
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities[0].accountID, "a")
    }

    func testSignatureKeepsExistingRichText() throws {
        let model = MailModel(quill: { _ in throw CancellationError() }, quillAllowed: { false }, draftStore: nil)
        model.senders = [.init(accountID: "fixture", address: "me@example.com", name: "Me", signature: "My signature")]
        var draft = MailModel.Draft(fromAccountID: "fixture", fromAddress: "me@example.com", body: "Bold answer")
        let original = NSAttributedString(string: draft.body, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        draft.richText = try original.data(from: NSRange(location: 0, length: original.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        model.draft = draft
        model.insertSignature()
        let result = try XCTUnwrap(model.draft)
        XCTAssertEqual(result.body, "Bold answer\n\nMy signature")
        let styled = MailRichText.attributed(result.richText, plain: result.body)
        let font = try XCTUnwrap(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertTrue(MailRichText.html(result.richText, plain: result.body).contains("My signature"))
    }
}
