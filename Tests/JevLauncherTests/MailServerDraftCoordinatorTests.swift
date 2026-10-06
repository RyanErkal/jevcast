import AppKit
import Foundation
import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailServerDraftCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-server-draft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private nonisolated static func reference(_ suffix: String, account: String = "fixture") -> MailServerDraftReference {
        .init(accountID: account, mailboxID: 7, uidValidity: 11, uid: UInt32(abs(suffix.hashValue) % 1000 + 1),
              messageID: "<\(suffix)@example.com>", digest: String(repeating: "a", count: 64))
    }

    private func model() -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, draftStore: nil)
        model.senders = [.init(accountID: "fixture", address: "me@example.com", name: "Me", signature: "")]
        return model
    }

    private func fixtureDraft(to: String = "sam@example.com", body: String) -> MailModel.Draft {
        var draft = MailModel.Draft(fromAccountID: "fixture", fromAddress: "me@example.com", to: to, body: body)
        draft.backend = MailBackend.jevcast.rawValue
        return draft
    }

    func testOlderDraftJSONDecodesWhenNewServerKeysAreAbsent() throws {
        var draft = fixtureDraft(body: "Hello")
        let source = try XCTUnwrap(MIMEMessage.parse(Data("From: Sam <sam@example.com>\r\n\r\nHello".utf8)))
        draft.source = .init(rowID: 4, message: source, html: nil)
        let encoded = try JSONEncoder().encode(draft)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["serverDraftReference", "previousServerDraftReference", "serverDraftBlockedReason",
                    "serverDraftAcknowledgementUncertain", "serverDraftInReplyTo", "serverDraftReferences",
                    "serverDraftHTML", "serverDraftHTMLBody"] { object.removeValue(forKey: key) }
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MailModel.Draft.self, from: old)
        XCTAssertEqual(decoded.id, draft.id)
        XCTAssertEqual(decoded.body, "Hello")
        XCTAssertNil(decoded.serverDraftReference)
        XCTAssertNil(decoded.serverDraftReferences)
    }

    func testStaleServerResultUpdatesOnlyServerMetadataOnNewerDraft() async throws {
        let model = model()
        let gate = AsyncGate()
        var first = fixtureDraft(body: "old")
        let oldID = first.id
        var saves = 0
        let coordinator = MailServerDraftCoordinator(model: model, save: { account, _, _, _ in
            saves += 1
            if saves == 1 { await gate.wait() }
            return Self.reference("saved\(saves)", account: account)
        }, remove: { _ in }, cleanupStore: MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json")), debounceNanoseconds: 1_000_000)
        model.draft = first
        coordinator.changed(first)
        try await Task.sleep(nanoseconds: 30_000_000)
        first.body = "newer"
        model.draft = first
        coordinator.changed(first)
        gate.open()
        try await eventually { saves >= 2 }
        XCTAssertEqual(model.draft?.id, oldID)
        XCTAssertEqual(model.draft?.body, "newer")
        XCTAssertNotNil(model.draft?.serverDraftReference)
    }

    func testDifferentDraftIsNeverClobberedByOlderServerResult() async throws {
        let model = model()
        let gate = AsyncGate()
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
            await gate.wait()
            return Self.reference("old")
        }, remove: { _ in }, cleanupStore: MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json")), debounceNanoseconds: 1_000_000)
        var old = fixtureDraft(body: "old")
        model.draft = old; coordinator.changed(old)
        try await Task.sleep(nanoseconds: 30_000_000)
        old.body = "new draft body"
        model.draft = fixtureDraft(to: "ann@example.com", body: "different")
        gate.open()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.draft?.to, "ann@example.com")
        XCTAssertEqual(model.draft?.body, "different")
    }

    func testUncertainAppendBlocksAutomaticRetry() async throws {
        let model = model()
        let failure = MailServerDraftError.acknowledgementUncertain(messageID: "<draft@example.com>", digest: String(repeating: "a", count: 64), candidate: nil, replacing: nil)
        var saves = 0
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
            saves += 1
            throw failure
        }, remove: { _ in }, cleanupStore: MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json")), debounceNanoseconds: 1_000_000)
        var draft = fixtureDraft(body: "check")
        model.draft = draft; coordinator.changed(draft)
        try await eventually { model.draft?.serverDraftAcknowledgementUncertain == true }
        draft.body = "edited"
        model.draft = draft; coordinator.changed(draft)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(model.draft?.serverDraftBlockedReason?.isEmpty == false)
    }

    func testSignInFailureStopsAutosaveUntilExplicitCoordinatorRestart() async throws {
        let model = model()
        var saves = 0
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
            saves += 1
            throw MailError.signInFailed("fixture credentials rejected")
        }, remove: { _ in }, cleanupStore: MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json")), debounceNanoseconds: 1_000_000)
        var draft = fixtureDraft(body: "credentials")

        model.draft = draft
        coordinator.changed(draft)
        try await eventually { model.draft?.serverDraftBlockedReason?.isEmpty == false }
        draft = try XCTUnwrap(model.draft)
        draft.body = "edited"
        model.draft = draft
        coordinator.changed(draft)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(saves, 1)
        XCTAssertTrue(model.serverDraftIsBlocked)
    }

    func testAccountSwitchDoesNotReplaceOldAccountReference() async throws {
        let model = model()
        var saves = 0
        let coordinator = MailServerDraftCoordinator(model: model, save: { account, _, _, _ in
            saves += 1
            return Self.reference("account\(saves)", account: account)
        }, remove: { _ in }, cleanupStore: MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json")), debounceNanoseconds: 1_000_000)
        var draft = fixtureDraft(body: "one")
        model.draft = draft; coordinator.changed(draft)
        try await eventually { saves == 1 }
        draft.fromAccountID = "other"; draft.fromAddress = "other@example.com"
        model.draft = draft; coordinator.changed(draft)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(model.serverDraftIsBlocked)
    }

    func testAcceptedCleanupDoesNotInvokeSendAndPersistsNoResendableDraft() async throws {
        let model = model()
        var removed: [MailServerDraftReference] = []
        let store = MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json"))
        let ref = Self.reference("accepted")
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in ref }, remove: { removed.append($0) }, cleanupStore: store, debounceNanoseconds: 1_000_000)
        let draft = fixtureDraft(body: "accepted")
        model.draft = draft; coordinator.changed(draft)
        try await eventually { model.draft?.serverDraftReference == ref }
        await coordinator.completedSend(model.draft!)
        XCTAssertEqual(removed, [ref])
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testCleanupReloadRecoversAcceptedDeliveryPointerAfterJournalGap() async throws {
        let model = model()
        let id = UUID()
        let ref = Self.reference("restart-gap")
        model.deliveries = [.init(id: id, draft: nil, subject: "Accepted", recipient: "sam@example.com",
                                  date: Date(), state: .sent, note: nil, receipt: nil,
                                  serverDraftCleanupReferences: [ref])]
        let store = MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json"))
        let coordinator = MailServerDraftCoordinator(model: model, cleanupStore: store)

        await coordinator.reloadCleanupAsync()

        XCTAssertEqual(coordinator.pendingCleanupRecords.first?.draftID, id)
        XCTAssertEqual(coordinator.pendingCleanupRecords.first?.references, [ref])
        XCTAssertEqual(try store.load().first?.references, [ref])
    }

    func testDiscardWaitsForAdmittedSaveBeforeRemovingExactReference() async throws {
        let model = model()
        let gate = AsyncGate()
        let ref = Self.reference("discard-after-save")
        var removed: [MailServerDraftReference] = []
        let store = MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json"))
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
            await gate.wait()
            return ref
        }, remove: { removed.append($0) }, cleanupStore: store, debounceNanoseconds: 1_000_000)
        let draft = fixtureDraft(body: "discard")

        model.draft = draft
        coordinator.changed(draft)
        try await Task.sleep(nanoseconds: 30_000_000)
        coordinator.discard(draft)
        XCTAssertTrue(removed.isEmpty)

        gate.open()
        try await eventually { removed == [ref] }
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testSameSizeAttachmentReplacementChangesFields() {
        var draft = fixtureDraft(body: "file")
        draft.attachments = [.init(filename: "file.bin", mimeType: "application/octet-stream", data: Data([1, 2, 3]))]
        let before = draft.fields
        draft.attachments = [.init(filename: "file.bin", mimeType: "application/octet-stream", data: Data([4, 5, 6]))]
        XCTAssertNotEqual(before, draft.fields)
    }

    func testMissingCleanupDirectoryLoadsEmptyWithoutChangingParentMode() throws {
        let shared = directory.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
        let store = MailServerDraftCleanupStore(file: shared.appendingPathComponent("missing/cleanup.json"))
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: shared.path)[.posixPermissions] as? NSNumber).uint16Value

        XCTAssertEqual(try store.load(), [])

        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: shared.path)[.posixPermissions] as? NSNumber).uint16Value
        XCTAssertEqual(after, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("missing").path))
    }

    func testCleanupStoreRefusesCorruptAndSymlinkFiles() throws {
        let store = MailServerDraftCleanupStore(file: directory.appendingPathComponent("cleanup.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.file), corrupt)

        try FileManager.default.removeItem(at: store.file)
        let target = directory.appendingPathComponent("target.json")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.init(draftID: UUID(), accepted: true, references: [Self.reference("symlink")], reason: "test", createdAt: Date())))
        XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate())
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if lock.withLock({ openState }) { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if openState { continuation.resume() }
                else { waiters.append(continuation) }
            }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            openState = true
            let value = waiters
            waiters.removeAll()
            return value
        }
        pending.forEach { $0.resume() }
    }
}
