import AppKit
import XCTest
import LauncherCore
@testable import JevLauncher

/// When a draft closes, what it keeps: Escape, a click on another message, the Discard key, a mail
/// link while a draft is set aside, and the signature Jevcast put in. A model with no store and
/// invented demo mail stands in for Mail; nothing is sent.
@MainActor
final class MailDraftCloseTests: XCTestCase {
    private func demo(signature: String = "", automatic: Bool = true) -> (MailModel, UserDefaults, String) {
        let suite = "MailDraftCloseTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(automatic, forKey: MailSignatures.automaticKey)
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              setRead: { _, _, _, _ in }, deleteMessage: { _, _, _ in }, sendDraft: { _, _ in throw CancellationError() },
                              draftStore: nil, mailDefaults: defaults)
        let inbox = MailMailbox(rowID: 1, url: "imap://demo/INBOX", unread: 1, total: 2, serverRole: .inbox)
        let messages = (1...3).map { index in
            MailSummary(rowID: Int64(index), mailbox: 1, subject: "Subject \(index)", senderName: "Ada", senderAddress: "ada@example.com",
                        snippet: "", date: Date().addingTimeInterval(Double(-index * 60)), read: false, flagged: false, conversation: Int64(index))
        }
        model.installDemo(mailboxes: [inbox], messages: messages)
        model.serverDrafts = MailServerDraftCoordinator(model: model, save: nil, remove: nil, cleanupStore: nil)
        model.senders = [.init(accountID: "demo", address: "alex@example.com", name: "Alex", signature: signature),
                         .init(accountID: "demo2", address: "alex@other.example", name: "Alex", signature: "Alex Morgan")]
        model.select(1, byUser: false)
        return (model, defaults, suite)
    }

    // MARK: F4: Escape keeps edits to header fields

    func testEscapeKeepsAReplyWhoseHeaderFieldsChanged() async {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let page = MailPage(mail: model)

        model.reply(all: false)
        model.draft?.bcc = "boss@example.com"
        XCTAssertEqual(page.backTitle, "Save Draft")
        XCTAssertTrue(page.back())
        XCTAssertNotNil(model.draft, "A Bcc added to an empty reply is kept")
        XCTAssertTrue(model.draftSetAside)
        await model.finishDraftCheckpoint()
        XCTAssertEqual(model.draftNote, "Draft saved.")

        model.draft = nil
        model.reply(all: false)
        model.draft?.subject = "Re: Subject 1 (moved to Friday)"
        XCTAssertTrue(page.back())
        XCTAssertNotNil(model.draft, "A changed subject is kept")

        model.draft = nil
        model.forward()
        model.draft?.subject = "Fwd: for you"
        XCTAssertTrue(page.back())
        XCTAssertNotNil(model.draft, "A forward's changed subject is kept")

        model.draft = nil
        model.reply(all: false)
        XCTAssertEqual(page.backTitle, "Close")
        XCTAssertTrue(page.back())
        XCTAssertNil(model.draft, "A reply exactly as Jevcast filled it in closes without a copy")
    }

    func testARestoredDraftIsAlwaysKept() {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        // As a draft saved by an earlier build, or one from a server, comes back: no record of what Jevcast filled in.
        model.startDraft(MailModel.Draft(mode: .reply(all: false), to: "ada@example.com", subject: "Re: Subject 1"))
        model.closeDraft()
        XCTAssertNotNil(model.draft)
        XCTAssertTrue(model.draftSetAside)
    }

    // MARK: F5: ⇧⌘⌫ discards; ⌘⌫ stays with the text

    func testOnlyShiftCommandDeleteDiscardsAndAHeldKeyNeverConfirms() throws {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let page = MailPage(mail: model)
        model.compose(to: "ann@example.com")
        model.draft?.body = "Hello"
        XCTAssertFalse(page.handleTypingEvent(MailComposeRig.key("\u{7f}", .command, keyCode: 51)),
                       "⌘⌫ goes to the text, where it deletes to the start of the line")
        XCTAssertFalse(model.discardArmed)
        let discard = MailComposeRig.key("\u{7f}", [.command, .shift], keyCode: 51)
        XCTAssertTrue(page.handleTypingEvent(discard))
        XCTAssertTrue(model.discardArmed, "The first press asks")
        let held = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: true, keyCode: 51))
        XCTAssertTrue(page.handleTypingEvent(held), "A held key is taken, so the text does not get it")
        XCTAssertNotNil(model.draft, "A repeat of the same press never confirms")
        XCTAssertTrue(page.handleTypingEvent(discard))
        XCTAssertNil(model.draft, "A new press confirms")
    }

    // MARK: F8: a set-aside draft never blocks a new one

    func testAMailLinkOpensWhileADraftIsSetAside() throws {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let page = MailPage(mail: model)
        model.compose(to: "ann@example.com")
        model.draft?.body = "Kept for later"
        let kept = try XCTUnwrap(model.draft)
        XCTAssertTrue(page.back())
        XCTAssertTrue(model.draftSetAside)

        let link = try XCTUnwrap(MailtoLink(try XCTUnwrap(URL(string: "mailto:sam@example.com?subject=Hello"))))
        XCTAssertTrue(model.compose(link: link), "The link opens")
        XCTAssertEqual(model.draft?.to, "sam@example.com")
        XCTAssertFalse(model.draftSetAside)
        XCTAssertTrue(page.composing)
        XCTAssertEqual(model.savedDrafts.map(\.id).last, kept.id, "The closed draft stays in Drafts")
        XCTAssertEqual(model.savedDrafts.last?.body, "Kept for later")
        XCTAssertTrue(model.notSent.isEmpty, "It is not reported as a message that did not go")

        // An open draft you changed still is not replaced.
        model.draft?.body = "Typing"
        XCTAssertFalse(model.compose(link: link))
        XCTAssertEqual(model.draft?.body, "Typing")

        // The kept draft opens again from Drafts and leaves the saved list.
        model.draft = nil
        model.restoreSavedDraft(kept)
        XCTAssertEqual(model.draft?.id, kept.id)
        XCTAssertFalse(model.unsent.contains { $0.id == kept.id })
    }

    // MARK: F10 and F11: the signature Jevcast put in

    func testChangingFromNeverRewritesWordsThatEndLikeTheSignature() throws {
        let (model, _, suite) = demo(signature: "Lee")
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.compose(to: "sam@example.com")
        XCTAssertEqual(model.draft?.body, "\n\nLee")
        model.draft?.body = "Please call Lee"
        XCTAssertEqual(model.draft?.signsAutomatically, false, "The edit made the signature yours")
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "demo2" }).id)
        XCTAssertEqual(model.draft?.body, "Please call Lee", "Your words stay as you wrote them")
        // Even text that ends exactly like the signature again stays yours.
        model.draft?.body = "Hi\n\nAlex Morgan"
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "demo" }).id)
        XCTAssertEqual(model.draft?.body, "Hi\n\nAlex Morgan")
    }

    func testClickingAnotherMessageDropsAnUntouchedSignedDraft() {
        let (model, _, suite) = demo(signature: "Lee")
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let page = MailPage(mail: model)
        model.reply(all: false)
        XCTAssertTrue(page.composing)
        page.pick(2)
        XCTAssertNil(model.draft, "The same as Escape: an untouched draft goes")
        XCTAssertTrue(model.savedDrafts.isEmpty)

        model.reply(all: false)
        model.draft?.cc = "bo@example.com"
        page.pick(3)
        XCTAssertNotNil(model.draft, "A changed draft is kept")
        XCTAssertTrue(model.draftSetAside)
    }

    func testASignatureInsertedByHandIsNotAMessage() {
        let (model, _, suite) = demo(signature: "Lee", automatic: false)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.reply(all: false)
        XCTAssertEqual(model.draft?.body, "")
        model.insertSignature()
        XCTAssertEqual(model.draft?.body, "\n\nLee")
        XCTAssertEqual(model.draft?.sendProblem, "Write your reply first.", "A signature alone is still not a message")
        XCTAssertFalse(model.draft?.hasContent ?? true)
        model.draft?.body = "Yes\n\nLee"
        XCTAssertNil(model.draft?.sendProblem)
    }

    // MARK: R2 and R4: a draft whose send failed

    /// A failed draft, put back in the composer as a failed send puts it back.
    private func failedDraft(_ model: MailModel, uncertain: Bool = false) -> MailModel.Draft {
        var failed = MailModel.Draft(to: "sam@example.com", subject: "Plan", body: "First try")
        failed.uncertainSend = uncertain
        model.recordDelivery(failed, state: uncertain ? .uncertain : .failed, note: uncertain ? "May be sent." : "Not sent: refused.")
        model.startDraft(failed)
        return failed
    }

    func testOpenDraftInOutboxOpensTheNewestCopy() throws {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let failed = failedDraft(model)
        model.draft?.body = "Corrected"
        model.closeDraft()
        model.compose(to: "ann@example.com")
        model.draft?.body = "Another message"
        model.closeDraft()

        model.restoreDelivery(try XCTUnwrap(model.deliveries.first { $0.id == failed.id }))
        XCTAssertEqual(model.draft?.id, failed.id)
        XCTAssertEqual(model.draft?.body, "Corrected", "The edits made after the failed send stay")
        XCTAssertEqual(model.savedDrafts.filter { $0.id == failed.id }.count, 1, "One copy, not two")
        XCTAssertTrue(model.savedDrafts.contains { $0.body == "Another message" }, "The other draft stays in Drafts")
    }

    func testAllowResendAppliesToTheNewestCopy() throws {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let failed = failedDraft(model, uncertain: true)
        model.draft?.body = "Corrected"
        model.closeDraft()
        model.compose(to: "ann@example.com")
        model.closeDraft()
        model.restoreDelivery(try XCTUnwrap(model.deliveries.first { $0.id == failed.id }), allowResend: true)
        XCTAssertEqual(model.draft?.body, "Corrected")
        XCTAssertEqual(model.draft?.uncertainSend, false)
    }

    func testAFailedDraftKeepsItsWarningWhenSetAside() {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let failed = failedDraft(model)
        model.closeDraft()
        model.compose(to: "ann@example.com")
        XCTAssertEqual(model.notSent.map(\.id), [failed.id], "Outbox records the failure, so the warning stays")
        XCTAssertEqual(model.notSent.first?.reason, "Not sent: refused.")

        // A draft you only closed stays quiet.
        model.draft?.body = "Kept"
        model.closeDraft()
        model.compose()
        XCTAssertEqual(model.notSent.map(\.id), [failed.id])
    }

    // MARK: R3: one server draft, one local draft

    func testAServerDraftOpenedAgainReopensItsLocalCopy() throws {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let reference = MailServerDraftReference(accountID: "demo", mailboxID: 4, uidValidity: 7, uid: 42,
                                                 messageID: "<a@example.com>", digest: "abc")
        var server = MailModel.Draft(to: "sam@example.com", subject: "Server", body: "From the server")
        server.serverDraftReference = reference
        XCTAssertEqual(try model.openServerDraft(server), .imported(server))
        // A review block on the local copy.
        model.draft?.serverDraftBlockedReason = "The server draft needs review."
        model.closeDraft()
        model.compose(to: "ann@example.com")
        model.draft?.body = "Another"

        var again = MailModel.Draft(to: "sam@example.com", subject: "Server", body: "From the server")
        again.serverDraftReference = reference
        _ = try model.openServerDraft(again)
        XCTAssertEqual(model.draft?.id, server.id, "The local copy opens again")
        XCTAssertEqual(model.draft?.serverDraftBlockedReason, "The server draft needs review.", "Its review block stays")
        XCTAssertFalse(model.savedDrafts.contains { $0.id == again.id }, "No second local copy")
        XCTAssertTrue(model.savedDrafts.contains { $0.body == "Another" }, "The other draft is kept")
    }

    // MARK: R5: edits that must be kept

    func testFormattingOrAnotherAccountAloneKeepsAReply() throws {
        let (model, _, suite) = demo(signature: "Lee")
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.reply(all: false)
        XCTAssertEqual(model.draft?.body, "\n\nLee")
        let bold = NSAttributedString(string: "\n\nLee", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        model.draft?.richText = try bold.data(from: NSRange(location: 0, length: bold.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertTrue(model.draft?.needsKeeping == true, "Bold on the signature is an edit")
        model.closeDraft()
        XCTAssertNotNil(model.draft)

        model.draft = nil
        model.senders.append(.init(accountID: "demo3", address: "alex@example.com", name: "Alex", signature: "Lee"))
        model.reply(all: false)
        model.selectSender("demo3:alex@example.com")
        XCTAssertTrue(model.draft?.needsKeeping == true, "Another account with the same address is an edit")
    }

    func testDiscardAsksFirstForAReplyWhoseOnlyEditIsABcc() {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.reply(all: false)
        model.draft?.bcc = "boss@example.com"
        XCTAssertFalse(model.discardDraft(), "The first press asks")
        XCTAssertNotNil(model.draft)
        XCTAssertTrue(model.discardDraft())
        XCTAssertNil(model.draft)
    }

    private func storedModel(_ directory: URL, defaults: UserDefaults) -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              setRead: { _, _, _, _ in }, deleteMessage: { _, _, _ in }, sendDraft: { _, _ in throw CancellationError() },
                              draftStore: MailDraftStore(directory: directory), mailDefaults: defaults)
        model.serverDrafts = MailServerDraftCoordinator(model: model, save: nil, remove: nil, cleanupStore: nil)
        model.senders = [.init(accountID: "demo", address: "alex@example.com", name: "Alex", signature: "")]
        return model
    }

    func testADraftAfterARestartIsAlwaysKeptAndStaysSetAside() throws {
        let (_, defaults, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-drafts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        // An untouched new message is open when Jevcast quits.
        let first = storedModel(directory, defaults: defaults)
        first.compose()
        XCTAssertFalse(first.draft?.needsKeeping ?? true)
        let closed = try XCTUnwrap(first.draft?.id)
        try first.saveComposition()
        let restored = storedModel(directory, defaults: defaults)
        XCTAssertTrue(restored.draft?.needsKeeping == true, "A restored draft always counts as changed")
        restored.closeDraft()
        XCTAssertNotNil(restored.draft, "Escape keeps it")
        XCTAssertTrue(restored.draftSetAside)
        try restored.saveComposition()

        // After another restart the closed draft still blocks nothing.
        let again = storedModel(directory, defaults: defaults)
        XCTAssertTrue(again.draftSetAside)
        let link = try XCTUnwrap(MailtoLink(try XCTUnwrap(URL(string: "mailto:ann@example.com"))))
        XCTAssertTrue(again.compose(link: link), "A mail link opens")
        XCTAssertEqual(again.draft?.to, "ann@example.com")
        XCTAssertTrue(again.savedDrafts.contains { $0.id == closed }, "The closed draft stays in Drafts")
    }

    // MARK: R6: Insert Signature once

    func testInsertSignatureNeverAddsASecondOne() {
        let (model, _, suite) = demo(signature: "Lee")
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.reply(all: false)
        XCTAssertEqual(model.draft?.body, "\n\nLee")
        model.insertSignature()
        XCTAssertEqual(model.draft?.body, "\n\nLee", "The signature is there already")
        XCTAssertEqual(model.draft?.sendProblem, "Write your reply first.", "A signature alone is still not a message")
    }

    // MARK: T2: Edit Draft never skips a send's review

    private static let reference = MailServerDraftReference(accountID: "demo", mailboxID: 4, uidValidity: 7, uid: 42,
                                                            messageID: "<a@example.com>", digest: "abc")

    func testEditDraftOnTheClosedDraftThatMayHaveGoneWaitsForOutbox() throws {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        // A send that may have gone comes back to the composer, and Escape closes it.
        var held = MailModel.Draft(to: "sam@example.com", subject: "Server", body: "Edited here")
        held.serverDraftReference = Self.reference
        held.uncertainSend = true
        model.recordDelivery(held, state: .uncertain, note: "May be sent.")
        model.startDraft(held)
        model.closeDraft()
        XCTAssertTrue(model.draftSetAside)

        var remote = MailModel.Draft(to: "sam@example.com", subject: "Server", body: "From the server")
        remote.serverDraftReference = Self.reference
        XCTAssertThrowsError(try model.openServerDraft(remote), "Outbox decides first")
        XCTAssertFalse(model.unsent.contains { $0.id == remote.id }, "No second, sendable copy")
        XCTAssertEqual(model.draft?.id, held.id)
        XCTAssertTrue(model.draft?.uncertainSend == true)
        XCTAssertTrue(model.draftSetAside, "Nothing opened")
    }

    func testEditDraftOnTheOpenDraftWithNewerEditsOpensThatDraftOnly() throws {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var local = MailModel.Draft(to: "sam@example.com", subject: "Server", body: "Edited here")
        local.serverDraftReference = Self.reference
        local.serverDraftBlockedReason = "The server draft needs review."
        model.startDraft(local)
        model.closeDraft()

        var remote = MailModel.Draft(to: "sam@example.com", subject: "Server", body: "From the server")
        remote.serverDraftReference = Self.reference
        XCTAssertEqual(try model.openServerDraft(remote), .alreadyOpen(try XCTUnwrap(model.draft)))
        XCTAssertEqual(model.draft?.id, local.id, "The draft that holds the server message opens")
        XCTAssertEqual(model.draft?.serverDraftBlockedReason, "The server draft needs review.", "Its review block stays")
        XCTAssertFalse(model.unsent.contains { $0.id == remote.id }, "The server copy gets no draft of its own")
        XCTAssertFalse(model.savedDrafts.contains { $0.id == remote.id })
    }

    func testEditDraftWaitsWhileAnOlderReferenceIsBeingSent() throws {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var sending = MailModel.Draft(to: "sam@example.com", subject: "Server", body: "Going")
        sending.previousServerDraftReference = Self.reference
        model.recordDelivery(sending, state: .sending)
        // A copy of the same draft is still open here.
        model.startDraft(sending)
        var remote = MailModel.Draft(to: "sam@example.com", subject: "Server", body: "From the server")
        remote.serverDraftReference = Self.reference
        XCTAssertThrowsError(try model.openServerDraft(remote))
        XCTAssertFalse(model.unsent.contains { $0.id == remote.id })
    }

    // MARK: T3: "Draft saved." only once it is saved

    func testDraftSavedShowsOnlyAfterTheWriteAndQuittingCanWaitForIt() async throws {
        let (_, defaults, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-drafts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = storedModel(directory, defaults: defaults)
        model.compose(to: "ann@example.com")
        model.draft?.body = "Newest words"
        model.closeDraft()
        XCTAssertNil(model.draftNote, "Nothing says saved before the write ends")
        XCTAssertTrue(model.savingDraft)
        await model.finishDraftCheckpoint()
        XCTAssertEqual(model.draftNote, "Draft saved.")
        XCTAssertFalse(model.savingDraft)
        let restarted = storedModel(directory, defaults: defaults)
        XCTAssertEqual(restarted.draft?.body, "Newest words", "The write is on disk")
        XCTAssertTrue(restarted.draftSetAside)
    }

    func testAFailedDraftWriteSaysSoAndKeepsTheDraft() async throws {
        let (_, defaults, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-drafts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = storedModel(directory, defaults: defaults)
        model.compose(to: "ann@example.com")
        model.draft?.body = "Keep me"
        model.persistenceProblem = "The disk is full."
        model.closeDraft()
        await model.finishDraftCheckpoint()
        XCTAssertNil(model.draftNote)
        XCTAssertEqual(model.banner, "The draft could not be saved: The disk is full.")
        XCTAssertEqual(model.draft?.body, "Keep me", "The draft stays in memory")
    }

    // MARK: T4: a closed draft that did not go keeps its warning

    func testAFailedDraftClosedWithEscapeKeepsItsWarning() {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let failed = failedDraft(model)
        model.closeDraft()
        XCTAssertTrue(model.draftSetAside)
        XCTAssertEqual(model.notSent.map(\.id), [failed.id], "The warning stays while it is closed")
        XCTAssertEqual(model.notSent.first?.reason, "Not sent: refused.")
        model.showUnsent()
        XCTAssertFalse(model.draftSetAside, "Show opens it again")
        XCTAssertEqual(model.draft?.id, failed.id)

        // An uncertain send, too.
        model.draft = nil
        let uncertain = failedDraft(model, uncertain: true)
        model.closeDraft()
        XCTAssertEqual(model.notSent.map(\.id), [uncertain.id])

        // A draft you only closed stays quiet.
        model.draft = nil
        model.compose(to: "ann@example.com")
        model.draft?.body = "Kept"
        model.closeDraft()
        XCTAssertTrue(model.notSent.isEmpty)
    }

    // MARK: T5: one tracked signature

    func testInsertSignatureAfterChangingFromReplacesTheFirstOne() throws {
        let (model, _, suite) = demo(signature: "Lee", automatic: false)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.reply(all: false)
        model.insertSignature()
        XCTAssertEqual(model.draft?.body, "\n\nLee")
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "demo2" }).id)
        model.insertSignature()
        XCTAssertEqual(model.draft?.body, "\n\nAlex Morgan", "The new signature replaces the first one")
        XCTAssertEqual(model.draft?.sendProblem, "Write your reply first.", "Signatures alone are not a message")

        // Your text stays; a signature you changed stays as your text.
        model.draft?.richText = nil
        model.draft?.body = "Yes\n\nAlex Morgan!"
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "demo" }).id)
        model.insertSignature()
        XCTAssertEqual(model.draft?.body, "Yes\n\nAlex Morgan!\n\nLee")
        XCTAssertNil(model.draft?.sendProblem)
    }

    // MARK: T6: the note survives leaving Mail

    func testLeavingMailKeepsTheDraftSavedNote() async {
        let (model, _, suite) = demo()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.draftNote = "Draft saved."
        let wait = Task { await MailBanner.expireDraftNote("Draft saved.", model, after: 5_000_000_000) }
        wait.cancel()
        await wait.value
        XCTAssertEqual(model.draftNote, "Draft saved.", "A cancelled wait leaves the note for the next visit")
        await MailBanner.expireDraftNote("Draft saved.", model, after: 1_000_000)
        XCTAssertNil(model.draftNote, "Its full time clears it")
    }

    // MARK: R15

    func testTheRecipientPlaceholderFitsTheNarrowestField() {
        let width = NSAttributedString(string: ComposeView.recipientPlaceholder,
                                       attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width
        XCTAssertLessThanOrEqual(width, MailRecipientChipField.minimumWidth - 4, "It never runs under Cc/Bcc")
    }
}
