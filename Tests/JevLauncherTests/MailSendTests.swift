import XCTest
import LauncherCore
@testable import JevLauncher

/// Sending from the mail views: Undo stops a send, a new draft or Send sends a waiting message at
/// once, a failed send never loses text, and Quill writes only into its own draft. A fake send
/// action stands in for Apple Mail.
@MainActor
final class MailSendTests: XCTestCase {
    private var rig: MailComposeRig!

    override func setUp() async throws { rig = try MailComposeRig() }
    override func tearDown() async throws { rig.remove() }

    private func replyWith(_ text: String, in model: MailModel) {
        model.reply(all: false)
        model.draft?.body = text
    }

    // MARK: Undo and the send queue

    func testUnavailableSendingAccountRefusesWithoutUsingAnotherAccount() async throws {
        let model = try await rig.model(delay: 0)
        model.compose(to: "sam@example.com"); model.draft?.body = "Keep this draft"
        model.draft?.fromAccountID = "removed-account"
        XCTAssertEqual(model.send(), "Select an available sending account.")
        XCTAssertFalse(model.sending)
        XCTAssertTrue(rig.outbox.all.isEmpty)
    }

    func testSourceChangeRefusesAQueuedSendAndKeepsTheDraft() async throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: MailBackend.key)
        defer {
            if let previous { defaults.set(previous, forKey: MailBackend.key) }
            else { defaults.removeObject(forKey: MailBackend.key) }
        }
        defaults.set(MailBackend.appleMail.rawValue, forKey: MailBackend.key)
        let model = try await rig.model(delay: 30)
        replyWith("Keep this reply", in: model)
        XCTAssertNil(model.send())
        defaults.set(MailBackend.jevcast.rawValue, forKey: MailBackend.key)
        await model.finishSends()
        XCTAssertTrue(rig.outbox.all.isEmpty)
        XCTAssertEqual(model.draft?.body, "Keep this reply")
        XCTAssertEqual(model.deliveries.last?.state, .failed)
        XCTAssertTrue(model.banner?.contains("mail source changed") == true)
    }

    func testReplySelectsTheOriginalAccountInsteadOfTheFirstAccount() async throws {
        let model = try await rig.model(delay: 0)
        model.senders.insert(.init(accountID: "other-account", address: "other@example.com", name: "Other", signature: ""), at: 0)
        model.reply(all: true)
        XCTAssertEqual(model.draft?.fromAccountID, "GMAIL-1")
        XCTAssertEqual(model.draft?.fromAddress, "me@example.com")
        XCTAssertEqual(Set(model.draft?.ownAddresses ?? []), ["me@example.com", "other@example.com"])
    }

    func testUndoBringsTheDraftBackAndSendsNothing() async throws {
        let model = try await rig.model(delay: 30)
        replyWith("See you Friday", in: model)
        model.send()
        XCTAssertNil(model.draft, "The composer closes at once")
        XCTAssertEqual(model.pendingSend?.body, "See you Friday")
        XCTAssertTrue(model.sending)
        model.undoSend()
        XCTAssertEqual(model.draft?.body, "See you Friday")
        XCTAssertEqual(model.banner, "Not sent. Your message is back.")
        XCTAssertNil(model.pendingSend)
        XCTAssertFalse(model.sending)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(rig.outbox.all.isEmpty)
    }

    func testASendGoesOutAfterTheUndoTime() async throws {
        let model = try await rig.model(delay: 0.05)
        model.reply(all: true)
        model.draft?.body = "Works for me"
        model.send()
        try await rig.wait { rig.outbox.all.count == 1 && model.banner == "Sent." }
        XCTAssertEqual(rig.outbox.all.first?.body, "Works for me")
        XCTAssertEqual(rig.outbox.all.first?.mode, .reply(all: true))
        XCTAssertNil(model.draft)
        XCTAssertFalse(model.sending)
    }

    func testANewDraftSendsTheWaitingMessageAtOnce() async throws {
        let model = try await rig.model(delay: 30)
        replyWith("First", in: model)
        model.send()
        model.compose(to: "ann@example.com")
        XCTAssertNil(model.pendingSend, "Undo is no longer offered")
        try await rig.wait { rig.outbox.all.map(\.body) == ["First"] }
        XCTAssertEqual(model.draft?.mode, .new)
    }

    func testSendWhileAMessageWaitsSendsTheWaitingOneFirst() async throws {
        let model = try await rig.model(delay: 30)
        replyWith("First", in: model)
        model.send()
        model.draft = MailModel.Draft(fromAccountID: "GMAIL-1", fromAddress: "me@example.com", mode: .new, to: "ann@example.com", subject: "Second")
        model.send()
        XCTAssertEqual(model.pendingSend?.subject, "Second", "The new message waits for Undo")
        try await rig.wait { rig.outbox.all.map(\.body) == ["First"] }
        model.undoSend()
        XCTAssertEqual(model.draft?.subject, "Second")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.outbox.all.count, 1)
    }

    func testUndoWhileAnotherDraftIsOpenKeepsBoth() async throws {
        let model = try await rig.model(delay: 30)
        replyWith("Undone reply", in: model)
        model.send()
        // A draft set directly, as a restore could, while the reply waits.
        model.draft = MailModel.Draft(mode: .new, to: "ann@example.com", body: "Open draft")
        model.undoSend()
        XCTAssertEqual(model.draft?.body, "Open draft", "The open draft stays")
        XCTAssertNotEqual(model.banner, "Not sent. Your message is back.")
        XCTAssertEqual(model.unsent.map(\.draft.body), ["Undone reply"], "The undone reply is kept, not lost")
        model.showUnsent()
        XCTAssertEqual(model.draft?.body, "Open draft", "Show does not replace a draft with text")
        XCTAssertEqual(model.banner, "Finish or discard your open message first.")
        model.draft = nil
        model.showUnsent()
        XCTAssertEqual(model.draft?.body, "Undone reply")
        XCTAssertTrue(model.unsent.isEmpty)
    }

    // MARK: Failed sends

    func testAFailedSendBringsTheDraftBack() async throws {
        rig.outbox.failing(with: LauncherError("Mail did not take the text, so nothing was sent."))
        let model = try await rig.model(delay: 0)
        var reported: [String] = []
        model.onSendFailure = { reported.append($0) }
        replyWith("Important answer", in: model)
        model.send()
        try await rig.wait { model.banner?.hasPrefix("Not sent:") == true }
        XCTAssertEqual(model.draft?.body, "Important answer")
        XCTAssertTrue(model.banner?.contains("Mail did not take the text") == true)
        XCTAssertEqual(reported.count, 1, "The app hears of it, to show it when no mail view is on screen")
        XCTAssertTrue(reported.first?.contains("Open Mail in Jevcast") == true)
    }

    func testAFailedSendWhileAnotherDraftIsOpenIsKept() async throws {
        rig.outbox.failing(with: LauncherError("Mail is not responding."))
        let model = try await rig.model(delay: 30)
        replyWith("Will fail", in: model)
        model.send()
        // Starting a new draft sends the waiting reply now; it fails while the new one has text.
        model.compose(to: "ann@example.com")
        model.draft?.body = "Newer message"
        try await rig.wait { !model.unsent.isEmpty }
        XCTAssertEqual(model.draft?.body, "Newer message")
        XCTAssertEqual(model.unsent.first?.draft.body, "Will fail")
        XCTAssertEqual(model.unsent.first?.reason, "Not sent: Mail is not responding.")
    }

    func testASendMailMayHaveMadeKeepsTheDraftAndSaysToCheckSent() async throws {
        rig.outbox.failing(with: MailMaybeSentError())
        let model = try await rig.model(delay: 0)
        replyWith("Maybe sent", in: model)
        model.send()
        try await rig.wait { model.draft != nil }
        XCTAssertEqual(model.draft?.body, "Maybe sent")
        XCTAssertEqual(model.banner, MailMaybeSentError().errorDescription)
        XCTAssertFalse(model.banner?.hasPrefix("Not sent") == true)
        XCTAssertTrue(model.draft?.uncertainSend == true)
        XCTAssertEqual(model.deliveries.last?.state, .uncertain)
        XCTAssertNotNil(model.send(), "An uncertain send needs explicit review before resend")
        XCTAssertEqual(rig.outbox.all.count, 1)
    }

    // MARK: Quitting

    func testFinishSendsSendsAWaitingMessageNow() async throws {
        let model = try await rig.model(delay: 30)
        replyWith("Before quitting", in: model)
        model.send()
        await model.finishSends()
        XCTAssertEqual(rig.outbox.all.map(\.body), ["Before quitting"])
        XCTAssertFalse(model.sending)
    }

    // MARK: Quill

    func testQuillWritesOnlyIntoItsOwnUnchangedDraft() async throws {
        let gate = QuillGate()
        let model = try await rig.model(delay: 0) { _ in try await gate.reply() }

        // Applied: the same draft, unchanged.
        model.reply(all: false)
        model.draft?.instruction = "say yes"
        model.draftWithQuill()
        XCTAssertTrue(model.quillBusy)
        XCTAssertEqual(model.send(), "Wait until Quill finishes writing.", "No send while Quill writes")
        gate.open()
        try await rig.wait { !model.quillBusy }
        XCTAssertEqual(model.draft?.body, "Quill text")

        // Dropped: the body changed meanwhile.
        gate.reset()
        model.draftWithQuill()
        model.draft?.body = "My own words"
        gate.open()
        try await rig.wait { !model.quillBusy }
        XCTAssertEqual(model.draft?.body, "My own words")
        XCTAssertEqual(model.composeNote, "Quill's text was not used because you changed the message.")

        // Dropped: another draft took its place.
        gate.reset()
        model.draftWithQuill()
        model.draft = nil
        model.forward()
        gate.open()
        try await rig.wait { !model.quillBusy }
        XCTAssertEqual(model.draft?.mode, .forward)
        XCTAssertEqual(model.draft?.body, "", "Quill's text for the reply never lands in the forward")
    }
}

/// Holds Quill's answer until the test opens it.
private final class QuillGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    func reset() { lock.withLock { isOpen = false } }
    func reply() async throws -> QuillReply {
        while !lock.withLock({ isOpen }) { try await Task.sleep(nanoseconds: 5_000_000) }
        return QuillReply(text: "Quill text", inputTokens: 0, outputTokens: 0, cost: nil)
    }
}
