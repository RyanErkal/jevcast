import XCTest
import LauncherCore
@testable import JevLauncher

/// Writing in the mail views: what a draft needs before it can go, one draft at a time, the keys
/// that start one, and Escape. A fake send action stands in for Apple Mail.
@MainActor
final class MailComposeTests: XCTestCase {
    private var rig: MailComposeRig!

    override func setUp() async throws { rig = try MailComposeRig() }
    override func tearDown() async throws { rig.remove() }

    func testWhatADraftNeedsBeforeItCanGo() {
        var reply = MailModel.Draft(mode: .reply(all: false), to: "sam@example.com")
        XCTAssertEqual(reply.sendProblem, "Write your reply first.")
        reply.body = "  \n\t "
        XCTAssertFalse(reply.canSend, "Only spaces and line breaks count as empty")
        reply.body = "Thanks"
        XCTAssertTrue(reply.canSend)

        var forward = MailModel.Draft(mode: .forward)
        XCTAssertEqual(forward.sendProblem, "Add a recipient.")
        forward.to = " , ; "
        XCTAssertEqual(forward.sendProblem, "Add a recipient.", "Separators alone are no recipient")
        forward.to = "not an address"
        XCTAssertEqual(forward.sendProblem, "“not an address” is not an email address.")
        forward.to = "ann@example.com"
        XCTAssertTrue(forward.canSend, "A forward may go without a note")

        XCTAssertEqual(MailModel.Draft(mode: .new).sendProblem, "Add a recipient.")
        var new = MailModel.Draft(mode: .new, to: "bob@example.com")
        XCTAssertEqual(new.sendProblem, "Write a subject or a message first.")
        new.subject = "Lunch"
        XCTAssertTrue(new.canSend)
        new.cc = "carl"
        XCTAssertEqual(new.sendProblem, "“carl” is not an email address.")
    }

    func testOnlyTypedTextCountsAsContent() {
        XCTAssertFalse(MailModel.Draft(mode: .reply(all: false), to: "sam@example.com", subject: "Re: Lunch").hasContent)
        XCTAssertFalse(MailModel.Draft(mode: .forward, subject: "Fwd: Lunch").hasContent)
        XCTAssertTrue(MailModel.Draft(mode: .forward, to: "ann@example.com").hasContent)
        XCTAssertTrue(MailModel.Draft(mode: .new, subject: "Lunch").hasContent)
        XCTAssertTrue(MailModel.Draft(mode: .reply(all: false), instruction: "say yes").hasContent)
        XCTAssertNotEqual(MailModel.Draft().id, MailModel.Draft().id)
    }

    func testAnEmptyReplyNeverReachesMail() async throws {
        let model = try await rig.model(delay: 0)
        model.reply(all: false)
        XCTAssertEqual(model.send(), "Write your reply first.")
        XCTAssertEqual(model.composeNote, "Write your reply first.", "The composer's footer says why")
        XCTAssertNotNil(model.draft, "The reply stays open")
        XCTAssertNil(model.pendingSend)
        model.draft?.body = "Now with text"
        XCTAssertNil(model.composeNote, "Typing clears the note")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(rig.outbox.all.isEmpty)
    }

    func testANewMessageNeedsValidAddresses() async throws {
        let model = try await rig.model(delay: 0)
        model.compose(to: "not an address")
        model.draft?.subject = "Hi"
        XCTAssertEqual(model.send(), "“not an address” is not an email address.")
        XCTAssertNotNil(model.draft)
    }

    // MARK: One draft at a time

    func testReplyNeverReplacesADraftWithText() async throws {
        let model = try await rig.model(delay: 0)
        model.reply(all: false)
        model.draft?.body = "Half written"
        let open = try XCTUnwrap(model.draft)
        // The reader toolbar's Reply button, Forward, and ⌘N all start a draft the same way.
        model.reply(all: true)
        model.forward()
        model.compose(to: "ann@example.com")
        XCTAssertEqual(model.draft?.id, open.id)
        XCTAssertEqual(model.draft?.body, "Half written")
        XCTAssertEqual(model.banner, "Finish or discard your open reply first.")
        XCTAssertEqual(model.draftNudge, 3)
    }

    func testAnEmptyDraftMakesWayForANewOne() async throws {
        let model = try await rig.model(delay: 0)
        model.reply(all: false)
        let first = try XCTUnwrap(model.draft?.id)
        model.forward()
        XCTAssertEqual(model.draft?.mode, .forward)
        XCTAssertNotEqual(model.draft?.id, first)
        XCTAssertNil(model.banner)
    }

    func testAReplyKeyAfterShowingAnotherMessageBringsBackTheKeptReply() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        let other = try XCTUnwrap(model.messages.last?.rowID)
        model.reply(all: false)
        model.draft?.body = "Kept"
        page.show(other)
        XCTAssertTrue(page.draftHidden)
        XCTAssertFalse(page.isTyping)
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("r", .command)))
        XCTAssertEqual(model.draft?.body, "Kept", "The kept reply is not replaced")
        XCTAssertFalse(page.draftHidden, "The kept reply shows again")
        XCTAssertEqual(model.banner, "Finish or discard your open reply first.")
    }

    func testANewDraftShowsEvenWhenTheKeptOneWasHidden() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        model.reply(all: false)
        page.show(try XCTUnwrap(model.messages.last?.rowID))
        XCTAssertTrue(page.draftHidden)
        model.forward()
        XCTAssertEqual(model.draft?.mode, .forward, "An empty reply makes way")
        XCTAssertFalse(page.draftHidden, "A new draft never starts hidden")
    }

    // MARK: Keys

    func testCommandRRepliesInTheLauncherAndLettersType() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("r")), "Plain R types in the filter")
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("r", .shift)))
        XCTAssertNil(model.draft)
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("r", .command)))
        XCTAssertEqual(model.draft?.mode, .reply(all: false))
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("r", .command)), "While writing, keys go to the reply")
        model.draft = nil
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("r", [.command, .shift])))
        XCTAssertEqual(model.draft?.mode, .reply(all: true))
        model.draft = nil
        model.search = "re"
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("f", [.command, .shift])), "⇧⌘F forwards, also with text in the filter")
        XCTAssertEqual(model.draft?.mode, .forward)
        XCTAssertEqual(page.footerHints.first?.key, "⌘↩")
        XCTAssertEqual(page.backTitle, "Discard")
        model.draft = nil
        XCTAssertEqual(page.footerHints.map(\.key), ["⌘R", "⇧⌘F", "Space", "⌘N"])
        XCTAssertEqual(page.footerHints.first?.title, "Reply")
        XCTAssertNil(page.backTitle)
    }

    func testCommandZUndoesASendButShiftCommandZDoesNot() async throws {
        let model = try await rig.model(delay: 30)
        let page = MailPage(mail: model)
        model.reply(all: false)
        model.draft?.body = "Hello"
        model.send()
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("z", [.command, .shift])))
        XCTAssertNotNil(model.pendingSend)
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("z", .command)))
        XCTAssertNil(model.pendingSend)
        XCTAssertEqual(model.draft?.body, "Hello")
    }

    func testCommandNWritesANewMessageInThePanel() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("n")), "Plain N types in the filter")
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("n", [.command, .shift])))
        XCTAssertNil(model.draft)
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("n", .command)))
        XCTAssertEqual(model.draft?.mode, .new)
        XCTAssertTrue(page.isTyping, "The composer opens in the panel and takes the keys")
    }

    // MARK: Panel workspace

    func testReturnAndDoubleClickReadInThePanel() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        XCTAssertFalse(page.canPopOut, "Mail has no window of its own")
        XCTAssertEqual(page.openTitle, "Read")
        XCTAssertTrue(page.handle(.open(shift: false)))
        XCTAssertTrue(page.expanded, "Return reads the message across the panel")
        XCTAssertTrue(page.back())
        XCTAssertFalse(page.expanded, "Escape shows the sidebar and list again")
        let other = try XCTUnwrap(model.messages.last?.rowID)
        page.read(other)
        XCTAssertEqual(model.selectedID, other, "A double click reads the row it hit")
        XCTAssertTrue(page.expanded)
    }

    func testPickingAMailboxKeepsTheOpenDraftOnScreen() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        model.compose(to: "ann@example.com")
        model.draft?.body = "Half written"
        model.place = .sent
        model.place = .drafts
        XCTAssertEqual(model.draft?.body, "Half written", "A mailbox change never closes the draft")
        XCTAssertTrue(page.composing, "The composer stays beside the list")
        model.place = .outbox
        XCTAssertEqual(model.draft?.body, "Half written", "Outbox shows beside the draft")
        XCTAssertTrue(page.composing)
    }

    func testOutboxHasNoMessageKeyboardActionsOrReadHint() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        model.place = .outbox
        // A previously selected message may remain until the new list finishes loading.
        model.select(try XCTUnwrap(model.messages.last?.rowID), byUser: false)
        XCTAssertEqual(page.openTitle, "")
        XCTAssertEqual(page.footerHints.map(\.key), ["⌘N"])
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("r", .command)))
        XCTAssertFalse(page.handleEvent(MailComposeRig.key(" ")))
        XCTAssertNil(model.draft)
        page.read()
        XCTAssertFalse(page.expanded)
    }

    func testClickingAnotherMessageKeepsTheDraftAside() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        let other = try XCTUnwrap(model.messages.last?.rowID)
        model.reply(all: false)
        model.draft?.body = "Kept"
        page.pick(other)
        XCTAssertEqual(model.selectedID, other)
        XCTAssertTrue(page.draftHidden)
        XCTAssertEqual(model.banner, "Your unsent reply is kept. Press Escape to go back to it.")
        XCTAssertTrue(page.back())
        XCTAssertFalse(page.draftHidden, "Escape brings the kept reply back")
        XCTAssertEqual(model.draft?.body, "Kept")
    }

    func testPickingTheOpenDraftInDraftsShowsItAsItIs() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)
        model.compose(to: "ann@example.com")
        model.draft?.body = "Kept"
        page.pick(try XCTUnwrap(model.messages.last?.rowID))
        XCTAssertTrue(page.draftHidden)
        let open = try XCTUnwrap(model.draft)
        model.restoreSavedDraft(open)
        XCTAssertFalse(page.draftHidden, "The kept draft shows again")
        XCTAssertEqual(model.draft?.id, open.id)
        XCTAssertEqual(model.draft?.body, "Kept")
    }

    // MARK: Escape

    func testEscapeAsksTwiceForAnyDraftWithText() async throws {
        let model = try await rig.model(delay: 0)
        let page = MailPage(mail: model)

        model.compose(to: "ann@example.com")
        XCTAssertTrue(page.back())
        XCTAssertNotNil(model.draft, "A new message with only To is kept after one Escape")
        XCTAssertEqual(model.composeNote, "Press Escape or click Discard again to discard this message.")
        model.draft?.subject = "Lunch"
        XCTAssertTrue(page.back())
        XCTAssertNotNil(model.draft, "An edit asks again")
        XCTAssertTrue(page.back())
        XCTAssertNil(model.draft)

        model.forward()
        model.draft?.to = "bob@example.com"
        XCTAssertTrue(page.back())
        XCTAssertNotNil(model.draft, "A forward with a recipient is kept after one Escape")
        XCTAssertTrue(page.back())
        XCTAssertNil(model.draft)

        model.reply(all: false)
        XCTAssertTrue(page.back())
        XCTAssertNil(model.draft, "An empty reply goes at once")
        XCTAssertFalse(page.back())
    }

    // MARK: Who gets a reply

    func testReplyLineNamesWhoGetsIt() async throws {
        try rig.writeBodies(rowIDs: Array(1...10)) { _ in
            "Reply-To: Team List <list@example.com>\r\nTo: Ann <ann@example.com>, me@example.com, bob@example.com\r\n"
                + "Cc: Carl <carl@example.com>\r\nDelivered-To: me@example.com\r\n"
        }
        let model = try await rig.model(delay: 0)
        try await rig.wait { model.detail != nil }
        model.reply(all: false)
        let single = try XCTUnwrap(model.draft?.replyLine)
        XCTAssertEqual(single.text, "Team List <list@example.com> (Reply-To)")
        model.draft = nil
        model.reply(all: true)
        let all = try XCTUnwrap(model.draft?.replyLine)
        XCTAssertEqual(all.text, "Team List (Reply-To), and 3 others: Ann, bob@example.com, Carl", "Your own address is left out")
        XCTAssertEqual(all.detail.components(separatedBy: "\n").count, 4)
        XCTAssertTrue(all.detail.contains("Carl <carl@example.com>"))
    }

    func testReplyLineWithoutHeadersSaysWhatItDoesNotKnow() throws {
        let original = MailSummary(rowID: 1, mailbox: 1, subject: "Hi", senderName: "Sam", senderAddress: "sam@example.com",
                                   snippet: "", date: Date(), read: true, flagged: false, conversation: 1)
        XCTAssertEqual(ReplyLine(original: original, message: nil, all: false).text, "Sam <sam@example.com>")
        XCTAssertEqual(ReplyLine(original: original, message: nil, all: true).text, "Sam, and everyone else on the message")
    }

    // MARK: The answered message stays in view

    func testAReplyKeepsItsMessageWhenTheSelectionMoves() async throws {
        try rig.writeBodies(rowIDs: Array(1...10)) { _ in "Reply-To: help@example.com\r\n" }
        let model = try await rig.model(delay: 0)
        try await rig.wait { model.detail != nil }
        let answered = try XCTUnwrap(model.selected)
        model.reply(all: false)
        XCTAssertEqual(model.draft?.source?.rowID, answered.rowID)
        model.moveSelection(1)
        try await rig.wait { model.selectedID != answered.rowID && model.detail != nil }
        XCTAssertEqual(model.draft?.original?.rowID, answered.rowID)
        XCTAssertEqual(model.draft?.source?.message.header("Subject"), "Test \(answered.rowID)")
        XCTAssertEqual(model.draft?.replyLine?.text, "help@example.com (Reply-To)", "The To line does not follow the selection")
    }

    func testAQuickReplyTakesTheTextOnceItLoads() async throws {
        try rig.writeBodies(rowIDs: Array(1...10))
        let model = try await rig.model(delay: 0)
        let target = try XCTUnwrap(model.messages.last)
        model.select(target.rowID, byUser: true)
        model.reply(all: false)
        try await rig.wait { model.draft?.source != nil }
        XCTAssertEqual(model.draft?.source?.rowID, target.rowID)
    }
}
