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

    func testSignInFailureStopsAutosaveUntilExplicitRetry() async throws {
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
        XCTAssertEqual(model.draft?.serverDraftBlockKind, .signInRefused)
        draft = try XCTUnwrap(model.draft)
        draft.body = "edited"
        model.draft = draft
        coordinator.changed(draft)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(model.serverDraftIsBlocked)

        // A restarted coordinator reads the same block and still does not sign in on an edit.
        let restarted = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
            saves += 1
            return Self.reference("restart")
        }, remove: { _ in }, debounceNanoseconds: 1_000_000)
        draft.body = "edited again"
        model.draft = draft
        restarted.changed(draft)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(model.draft?.serverDraftBlockKind, .signInRefused)
        XCTAssertTrue(restarted.canRetryServerSave(try XCTUnwrap(model.draft)))
    }

    func testExplicitRetryAfterRepairedSignInKeepsDraftAndPersistsRecovery() async throws {
        let store = MailDraftStore(directory: directory.appendingPathComponent("composition"))
        var sends = 0
        func storedModel() -> MailModel {
            let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                                  sendDraft: { _, _ in sends += 1 }, undoDelay: 0, draftStore: store)
            model.senders = [.init(accountID: "fixture", address: "me@example.com", name: "Me", signature: "")]
            return model
        }
        let first = Self.reference("first-save")
        let repaired = Self.reference("repaired-save")
        let attachment = OutgoingMessage.Attachment(filename: "plan.txt", mimeType: "text/plain", data: Data("plan".utf8))

        // A saved server copy exists, then the account starts refusing sign-in.
        let broken = storedModel()
        var brokenSaves = 0
        let brokenCoordinator = MailServerDraftCoordinator(model: broken, save: { _, _, _, _ in
            brokenSaves += 1
            if brokenSaves == 1 { return first }
            throw MailError.signInFailed("fixture credentials rejected")
        }, remove: { _ in XCTFail("Recovery must not remove a draft") }, debounceNanoseconds: 1_000_000)
        var draft = fixtureDraft(body: "first")
        draft.attachments = [attachment]
        broken.draft = draft; brokenCoordinator.changed(draft)
        try await eventually { broken.draft?.serverDraftReference == first }
        draft = try XCTUnwrap(broken.draft)
        draft.body = "kept text"
        broken.draft = draft; brokenCoordinator.changed(draft)
        try await eventually { broken.draft?.serverDraftBlockKind == .signInRefused }
        draft = try XCTUnwrap(broken.draft)
        draft.subject = "Edited while blocked"
        broken.draft = draft; brokenCoordinator.changed(draft)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(brokenSaves, 2)
        try await broken.saveCompositionAsync()

        // After a restart and repaired fake credentials, one explicit retry replaces the exact UID.
        let model = storedModel()
        let restored = try XCTUnwrap(model.draft)
        XCTAssertEqual(restored.serverDraftBlockKind, .signInRefused)
        XCTAssertEqual(restored.serverDraftReference, first)
        var replaced: [MailServerDraftReference?] = []
        var savedRaw = Data()
        let coordinator = MailServerDraftCoordinator(model: model, save: { account, raw, _, replacing in
            XCTAssertEqual(account, "fixture")
            replaced.append(replacing); savedRaw = raw
            return repaired
        }, remove: { _ in XCTFail("Recovery must not remove a draft") }, debounceNanoseconds: 1_000_000)
        XCTAssertTrue(coordinator.canRetryServerSave(restored))

        let cleared = await coordinator.retryServerSave(restored)

        XCTAssertTrue(cleared)
        XCTAssertEqual(replaced, [first])
        XCTAssertTrue(String(decoding: savedRaw, as: UTF8.self).contains("Edited while blocked"))
        let recovered = try XCTUnwrap(model.draft)
        XCTAssertEqual(recovered.id, draft.id)
        XCTAssertEqual(recovered.messageID, draft.messageID)
        XCTAssertEqual(recovered.body, "kept text")
        XCTAssertEqual(recovered.subject, "Edited while blocked")
        XCTAssertEqual(recovered.attachments, [attachment])
        XCTAssertEqual(recovered.serverDraftReference, repaired)
        XCTAssertNil(recovered.previousServerDraftReference)
        XCTAssertNil(recovered.serverDraftBlockedReason)
        XCTAssertNil(recovered.serverDraftBlockKind)
        XCTAssertNil(recovered.serverDraftAcknowledgementUncertain)
        XCTAssertFalse(recovered.uncertainSend)
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(model.deliveries.isEmpty)
        XCTAssertNil(model.pendingSend)

        // The recovered state is on disk: a further restart does not bring back the old block.
        let reloaded = try XCTUnwrap(storedModel().draft)
        XCTAssertEqual(reloaded.body, "kept text")
        XCTAssertEqual(reloaded.attachments, [attachment])
        XCTAssertEqual(reloaded.serverDraftReference, repaired)
        XCTAssertNil(reloaded.serverDraftBlockedReason)
        XCTAssertNil(reloaded.serverDraftBlockKind)
        XCTAssertTrue(try store.load().deliveries.isEmpty)
        XCTAssertEqual(sends, 0)
    }

    func testRetryWithStillRefusedSignInBlocksAgainAndEditsDoNotRetry() async throws {
        let model = model()
        var saves = 0
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
            saves += 1
            throw MailError.signInFailed("fixture credentials rejected")
        }, remove: { _ in }, debounceNanoseconds: 1_000_000)
        var draft = fixtureDraft(body: "still broken")
        model.draft = draft; coordinator.changed(draft)
        try await eventually { model.draft?.serverDraftBlockKind == .signInRefused }

        let cleared = await coordinator.retryServerSave(try XCTUnwrap(model.draft))
        XCTAssertFalse(cleared)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(model.draft?.serverDraftBlockKind, .signInRefused)

        draft = try XCTUnwrap(model.draft)
        draft.body = "edited after failed retry"
        model.draft = draft; coordinator.changed(draft)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(saves, 2)
        XCTAssertTrue(coordinator.canRetryServerSave(try XCTUnwrap(model.draft)))
    }

    func testRetryCannotClearIdentityOrUnclassifiedBlocks() async throws {
        let owned = Self.reference("owned")
        let newer = Self.reference("newer")
        var uncertain = fixtureDraft(body: "uncertain")
        uncertain.serverDraftReference = owned
        uncertain.serverDraftBlockedReason = "APPEND was not acknowledged."
        uncertain.serverDraftBlockKind = .signInRefused
        uncertain.serverDraftAcknowledgementUncertain = true
        var partial = fixtureDraft(body: "partial")
        partial.serverDraftReference = newer
        partial.previousServerDraftReference = owned
        partial.serverDraftBlockedReason = "The previous server draft could not be removed."
        partial.serverDraftBlockKind = .signInRefused
        var switched = fixtureDraft(body: "switched")
        switched.serverDraftReference = owned
        switched.serverDraftBlockedReason = "This draft was switched to another account."
        var legacy = fixtureDraft(body: "legacy")
        legacy.serverDraftBlockedReason = MailError.signInFailed("saved by an older build").localizedDescription

        for blocked in [uncertain, partial, switched, legacy] {
            let model = model()
            var saves = 0
            let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
                saves += 1
                return Self.reference("must-not-save")
            }, remove: { _ in XCTFail("Retry must not remove a draft") }, debounceNanoseconds: 1_000_000)
            model.draft = blocked

            XCTAssertFalse(coordinator.canRetryServerSave(blocked), blocked.body)
            let cleared = await coordinator.retryServerSave(blocked)
            XCTAssertFalse(cleared, blocked.body)
            XCTAssertEqual(saves, 0, blocked.body)
            XCTAssertEqual(model.draft?.serverDraftBlockedReason, blocked.serverDraftBlockedReason, blocked.body)
            XCTAssertEqual(model.draft?.serverDraftReference, blocked.serverDraftReference, blocked.body)
            XCTAssertEqual(model.draft?.previousServerDraftReference, blocked.previousServerDraftReference, blocked.body)
            await XCTAssertThrowsErrorAsync(try await coordinator.prepareForSend(blocked), blocked.body)
        }
    }

    func testUncertainAppendDuringRetryReplacesSignInBlockAndCannotBeRetried() async throws {
        let model = model()
        var saves = 0
        let candidate = Self.reference("candidate")
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, messageID, replacing in
            saves += 1
            if saves == 1 { throw MailError.signInFailed("fixture credentials rejected") }
            throw MailServerDraftError.acknowledgementUncertain(messageID: messageID, digest: String(repeating: "a", count: 64),
                                                                candidate: candidate, replacing: replacing)
        }, remove: { _ in }, debounceNanoseconds: 1_000_000)
        let draft = fixtureDraft(body: "append unclear")
        model.draft = draft; coordinator.changed(draft)
        try await eventually { model.draft?.serverDraftBlockKind == .signInRefused }

        let cleared = await coordinator.retryServerSave(try XCTUnwrap(model.draft))

        XCTAssertFalse(cleared)
        XCTAssertEqual(model.draft?.serverDraftAcknowledgementUncertain, true)
        XCTAssertNil(model.draft?.serverDraftBlockKind)
        XCTAssertEqual(model.draft?.serverDraftReference, candidate)
        XCTAssertFalse(coordinator.canRetryServerSave(try XCTUnwrap(model.draft)))
        let again = await coordinator.retryServerSave(try XCTUnwrap(model.draft))
        XCTAssertFalse(again)
        XCTAssertEqual(saves, 2)
    }

    func testRetryAfterAccountSwitchKeepsOwnedReferenceAndBlocksWithoutSaving() async throws {
        let model = model()
        let owned = Self.reference("owned-before-switch")
        var saves = 0
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, _, _, _ in
            saves += 1
            if saves == 1 { return owned }
            throw MailError.signInFailed("fixture credentials rejected")
        }, remove: { _ in XCTFail("Retry must not remove a draft") }, debounceNanoseconds: 1_000_000)
        var draft = fixtureDraft(body: "first")
        model.draft = draft; coordinator.changed(draft)
        try await eventually { model.draft?.serverDraftReference == owned }
        draft = try XCTUnwrap(model.draft)
        draft.body = "second"
        model.draft = draft; coordinator.changed(draft)
        try await eventually { model.draft?.serverDraftBlockKind == .signInRefused }
        draft = try XCTUnwrap(model.draft)
        draft.fromAccountID = "other"; draft.fromAddress = "other@example.com"
        model.draft = draft; coordinator.changed(draft)

        let cleared = await coordinator.retryServerSave(try XCTUnwrap(model.draft))

        XCTAssertFalse(cleared)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(model.draft?.serverDraftReference, owned)
        XCTAssertNil(model.draft?.serverDraftBlockKind)
        XCTAssertTrue(model.draft?.serverDraftBlockedReason?.contains("another account") == true)
        XCTAssertFalse(coordinator.canRetryServerSave(try XCTUnwrap(model.draft)))
    }

    func testEditsDuringRetryAreSavedAfterRecoveryInOrder() async throws {
        let model = model()
        let gate = AsyncGate()
        let first = Self.reference("retry-result")
        let second = Self.reference("after-edit")
        var saves = 0
        var raws: [String] = []
        var replaced: [MailServerDraftReference?] = []
        let coordinator = MailServerDraftCoordinator(model: model, save: { _, raw, _, replacing in
            saves += 1
            if saves == 1 { throw MailError.signInFailed("fixture credentials rejected") }
            raws.append(String(decoding: raw, as: UTF8.self)); replaced.append(replacing)
            if saves == 2 { await gate.wait(); return first }
            return second
        }, remove: { _ in }, debounceNanoseconds: 1_000_000)
        var draft = fixtureDraft(body: "before")
        model.draft = draft; coordinator.changed(draft)
        try await eventually { model.draft?.serverDraftBlockKind == .signInRefused }

        let retry = Task { await coordinator.retryServerSave(try! XCTUnwrap(model.draft)) }
        try await eventually { saves == 2 }
        XCTAssertTrue(coordinator.retryingDraftIDs.contains(draft.id))
        let duplicate = await coordinator.retryServerSave(try XCTUnwrap(model.draft))
        XCTAssertFalse(duplicate)
        draft = try XCTUnwrap(model.draft)
        draft.subject = "Typed during retry"
        model.draft = draft; coordinator.changed(draft)
        gate.open()

        let cleared = await retry.value
        XCTAssertTrue(cleared)
        try await eventually { saves == 3 }
        XCTAssertFalse(raws[0].contains("Typed during retry"))
        XCTAssertTrue(raws[1].contains("Typed during retry"))
        XCTAssertEqual(replaced, [nil, first])
        try await eventually { model.draft?.serverDraftReference == second }
        XCTAssertEqual(model.draft?.subject, "Typed during retry")
        XCTAssertFalse(coordinator.retryingDraftIDs.contains(draft.id))
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

    private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("Expected an error: " + message, file: file, line: line) }
        catch {}
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
