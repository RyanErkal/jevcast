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
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
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
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              sendDraft: { _, _ in attempts += 1 }, undoDelay: 0, draftStore: MailDraftStore(directory: directory))
        model.senders = [.init(accountID: "fixture", address: "me@example.com", name: "Me", signature: "")]
        model.compose(to: "sam@example.com"); model.draft?.body = "Do not send"
        XCTAssertNotNil(model.send())
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testHistoryLimitPreservesPendingServerDraftCleanupAcrossRestart() async throws {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              statusProvider: { .noMail }, draftStore: nil)
        let accepted = MailModel.Draft(backend: MailBackend.jevcast.rawValue, to: "sam@example.com", subject: "Needs cleanup")
        let reference = MailServerDraftReference(accountID: "fixture", mailboxID: 1, uidValidity: 7, uid: 8,
                                                messageID: accepted.sendingMessageID, digest: String(repeating: "a", count: 64))
        model.recordDelivery(accepted, state: .sent)
        model.deliveries[0].serverDraftCleanupReferences = [reference]
        for number in 0..<35 {
            model.recordDelivery(.init(to: "sam@example.com", subject: "Sent \(number)"), state: .sent)
        }

        let store = MailDraftStore(directory: directory)
        try await model.saveCompositionAsync(to: store)
        let recovered = try XCTUnwrap(store.load().deliveries.first { $0.id == accepted.id })
        XCTAssertEqual(recovered.state, .sent)
        XCTAssertNil(recovered.draft, "An accepted message must not become resendable")
        XCTAssertEqual(recovered.serverDraftCleanupReferences, [reference])
        XCTAssertEqual(model.deliveries.filter { $0.id != accepted.id }.count, 30)
    }

    func testStoreRefusesSymlink() throws {
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try MailDraftStore(directory: directory).save(.init()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testStoreRefusesDanglingSymlink() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: missing)
        XCTAssertThrowsError(try MailDraftStore(directory: directory).load())
        XCTAssertThrowsError(try MailDraftStore(directory: directory).save(.init()))
    }

    func testCorruptSnapshotIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("composition.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: file, options: .atomic)
        XCTAssertThrowsError(try MailDraftStore(directory: directory).save(.init()))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testAtomicSaveLeavesLastGoodSnapshotDuringCrashRecovery() throws {
        let store = MailDraftStore(directory: directory)
        let draft = MailModel.Draft(to: "sam@example.com", subject: "Last good", body: "Keep me")
        try store.save(.init(active: draft))
        let abandoned = directory.appendingPathComponent(".composition-crash-left-behind")
        try Data("incomplete".utf8).write(to: abandoned)

        let loaded = try store.load()
        XCTAssertEqual(loaded.active, draft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testAsyncCanceledLargeAutosaveCannotOvertakeForcedSendingState() async throws {
        let store = MailDraftStore(directory: directory)
        var slow = MailModel.Draft(to: "sam@example.com", body: "old autosave")
        slow.attachments = [.init(filename: "large.bin", mimeType: "application/octet-stream",
                                   data: Data(repeating: 0x5a, count: 12 * 1024 * 1024))]
        let forced = MailModel.Draft(to: "sam@example.com", body: "forced sending")
        let sending = MailDelivery(id: forced.id, draft: forced, subject: forced.subject,
                                   recipient: forced.to, date: Date(), state: .sending)

        let autosave = Task { try await store.saveAsync(.init(active: slow)) }
        await Task.yield()
        autosave.cancel()
        try await store.saveAsync(.init(active: nil, deliveries: [sending]))
        _ = try? await autosave.value

        let raw = try Data(contentsOf: directory.appendingPathComponent("composition.json"))
        let final = try JSONDecoder().decode(MailDraftStore.Snapshot.self, from: raw)
        XCTAssertEqual(final.deliveries.first?.state, .sending)
        XCTAssertEqual(final.deliveries.first?.draft?.body, "forced sending")
    }

    func testAsyncSaveKeepsMainActorResponsiveForLargeSnapshot() async throws {
        let store = MailDraftStore(directory: directory)
        var draft = MailModel.Draft(to: "sam@example.com", body: "large")
        draft.attachments = [.init(filename: "large.bin", mimeType: "application/octet-stream",
                                   data: Data(repeating: 0x42, count: 16 * 1024 * 1024))]
        let marker = expectation(description: "main actor marker")
        let save = Task { try await store.saveAsync(.init(active: draft)) }
        await Task.yield()
        Task { @MainActor in marker.fulfill() }
        await fulfillment(of: [marker], timeout: 1)
        try await save.value
    }

    func testModelAsyncCompositionSaveCapturesCurrentSnapshot() async throws {
        let store = MailDraftStore(directory: directory)
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, draftStore: nil)
        model.draft = MailModel.Draft(to: "sam@example.com", subject: "Async", body: "Captured")
        try await model.saveCompositionAsync(to: store)
        XCTAssertEqual(try store.load().active?.body, "Captured")
    }

    func testCompositionDirectoryIsOwnerOnly() throws {
        let store = MailDraftStore(directory: directory)
        try store.save(.init())
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("composition.json").path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
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
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, draftStore: nil)
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
