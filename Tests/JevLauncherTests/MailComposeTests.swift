import XCTest
import LauncherCore
@testable import JevLauncher

/// Sending from the mail views: an empty reply never goes out, Undo stops a send, and a send that
/// fails brings the draft back. A fake send action stands in for Apple Mail.
final class MailComposeTests: XCTestCase {
    private var root = ""

    private final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [MailModel.Draft] = []
        var fails = false
        func add(_ draft: MailModel.Draft) { lock.withLock { items.append(draft) } }
        var all: [MailModel.Draft] { lock.withLock { items } }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-compose-" + UUID().uuidString).path
        try MailFixture.build(root: root, layout: .init(gmailInbox: 5, allMailOnly: 0, sent: 0, trash: 0, exchangeInbox: 0, projects: 0, perFolder: 0))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }

    func testWhatADraftNeedsBeforeItCanGo() {
        var reply = MailModel.Draft(mode: .reply(all: false), to: "sam@example.com")
        XCTAssertEqual(reply.sendProblem, "Write your reply first.")
        reply.body = "  \n\t "
        XCTAssertFalse(reply.canSend, "Only spaces and line breaks count as empty")
        reply.body = "Thanks"
        XCTAssertTrue(reply.canSend)

        var forward = MailModel.Draft(mode: .forward)
        XCTAssertEqual(forward.sendProblem, "Add who to forward it to.")
        forward.to = "ann@example.com"
        XCTAssertTrue(forward.canSend, "A forward may go without a note")

        XCTAssertEqual(MailModel.Draft(mode: .new).sendProblem, "Add a recipient first.")
        var new = MailModel.Draft(mode: .new, to: "bob@example.com")
        XCTAssertEqual(new.sendProblem, "Write a subject or a message first.")
        new.subject = "Lunch"
        XCTAssertTrue(new.canSend)
    }

    @MainActor func testAnEmptyReplyNeverReachesMail() async throws {
        let outbox = Outbox()
        let model = try await readyModel(outbox, delay: 0)
        model.reply(all: false)
        model.send()
        XCTAssertEqual(model.banner, "Write your reply first.")
        XCTAssertNotNil(model.draft, "The reply stays open")
        XCTAssertNil(model.pendingSend)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(outbox.all.isEmpty)
    }

    @MainActor func testUndoBringsTheDraftBackAndSendsNothing() async throws {
        let outbox = Outbox()
        let model = try await readyModel(outbox, delay: 30)
        model.reply(all: false)
        model.draft?.body = "See you Friday"
        model.send()
        XCTAssertNil(model.draft, "The composer closes at once")
        XCTAssertEqual(model.pendingSend?.body, "See you Friday")
        model.undoSend()
        XCTAssertEqual(model.draft?.body, "See you Friday")
        XCTAssertNil(model.pendingSend)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(outbox.all.isEmpty)
    }

    @MainActor func testASendGoesOutAfterTheUndoTime() async throws {
        let outbox = Outbox()
        let model = try await readyModel(outbox, delay: 0.05)
        model.reply(all: true)
        model.draft?.body = "Works for me"
        model.send()
        try await wait { outbox.all.count == 1 && model.banner == "Sent." }
        XCTAssertEqual(outbox.all.first?.body, "Works for me")
        XCTAssertEqual(outbox.all.first?.mode, .reply(all: true))
        XCTAssertNil(model.draft)
        XCTAssertFalse(model.sending)
    }

    @MainActor func testAFailedSendBringsTheDraftBack() async throws {
        let outbox = Outbox()
        outbox.fails = true
        let model = try await readyModel(outbox, delay: 0)
        model.reply(all: false)
        model.draft?.body = "Important answer"
        model.send()
        try await wait { model.banner?.hasPrefix("Not sent:") == true }
        XCTAssertEqual(model.draft?.body, "Important answer")
        XCTAssertTrue(model.banner?.contains("Mail did not take the text") == true)
    }

    @MainActor func testANewMessageNeedsValidAddresses() async throws {
        let outbox = Outbox()
        let model = try await readyModel(outbox, delay: 0)
        model.compose(to: "not an address")
        model.draft?.subject = "Hi"
        model.send()
        XCTAssertTrue(model.banner?.contains("is not an email address") == true)
        XCTAssertNotNil(model.draft)
    }

    @MainActor func testReplySummaryNamesWhoGetsIt() async throws {
        let model = try await readyModel(Outbox(), delay: 0)
        let selected = try XCTUnwrap(model.selected)
        model.reply(all: false)
        let single = try XCTUnwrap(model.draft)
        XCTAssertTrue(model.replySummary(for: single).contains(selected.senderAddress))
        model.reply(all: true)
        let all = try XCTUnwrap(model.draft)
        XCTAssertTrue(model.replySummary(for: all).hasSuffix("and everyone else on the message"))
    }

    // MARK: Helpers

    @MainActor private func readyModel(_ outbox: Outbox, delay: TimeInterval) async throws -> MailModel {
        let fixtureRoot = root
        let model = MailModel(quill: { _ in throw CancellationError() }, quillAllowed: { false }, statusProvider: { .ready(root: fixtureRoot) },
                              setRead: { _, _, _, _ in },
                              sendDraft: { draft, _ in
                                  outbox.add(draft)
                                  if outbox.fails { throw LauncherError("Mail did not take the text, so nothing was sent.") }
                              }, undoDelay: delay)
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        return model
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for the mail model")
    }
}
