import AppKit
import XCTest
import LauncherCore
@testable import JevLauncher

/// Automatic signatures in drafts, and the composer and layout choices around them. A model with
/// no store stands in for Mail; nothing is sent.
@MainActor
final class MailSignatureTests: XCTestCase {
    private func makeModel(defaults: UserDefaults? = nil) -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, statusProvider: { .noMail },
                              setRead: { _, _, _, _ in }, sendDraft: { _, _ in throw CancellationError() }, draftStore: nil,
                              mailDefaults: defaults)
        model.senders = [.init(accountID: "work", address: "alex@work.example", name: "Alex", signature: "Alex Morgan\nStudio\n"),
                         .init(accountID: "home", address: "alex@home.example", name: "Alex", signature: "Alex"),
                         .init(accountID: "plain", address: "alex@plain.example", name: "Alex", signature: "")]
        return model
    }

    private func newDraft(from account: String, address: String, body: String = "") -> MailModel.Draft {
        MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: account, fromAddress: address,
                        to: "sam@example.com", body: body, signsAutomatically: true)
    }

    func testANewDraftStartsWithTheAccountsSignature() {
        let model = makeModel()
        model.startDraft(newDraft(from: "work", address: "alex@work.example"))
        XCTAssertEqual(model.draft?.body, "\n\nAlex Morgan\nStudio")
        XCTAssertEqual(model.draft?.automaticSignature, "Alex Morgan\nStudio")
        XCTAssertEqual(model.draft?.typedBody, "")
        XCTAssertEqual(model.draft?.sendProblem, "Write a subject or a message first.", "A signature alone is not a message")
        model.draft?.to = ""
        XCTAssertFalse(model.draft?.hasContent ?? true, "An untouched draft with a signature closes without a copy")
    }

    func testAReplyIsSignedAboveTheOriginal() {
        let model = makeModel()
        var reply = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "home", fromAddress: "alex@home.example",
                                    mode: .reply(all: false), to: "sam@example.com", subject: "Re: Lunch", signsAutomatically: true)
        reply.includesQuote = true
        model.startDraft(reply)
        // The original goes below everything in the body when it is sent, so the signature sits above it.
        XCTAssertEqual(model.draft?.body, "\n\nAlex")
        XCTAssertEqual(model.draft?.sendProblem, "Write your reply first.")
        XCTAssertFalse(model.draft?.hasContent ?? true)
        model.draft?.body = "Yes, Friday works.\n\nAlex"
        XCTAssertTrue(model.draft?.canSend ?? false)
        XCTAssertEqual(model.draft?.typedBody, "Yes, Friday works.")
    }

    func testChangingFromSwapsAnUnchangedSignature() throws {
        let model = makeModel()
        model.startDraft(newDraft(from: "work", address: "alex@work.example"))
        model.draft?.body = "Hi Sam" + (model.draft?.body ?? "")
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "home" }).id)
        XCTAssertEqual(model.draft?.body, "Hi Sam\n\nAlex")
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "plain" }).id)
        XCTAssertEqual(model.draft?.body, "Hi Sam", "An account without a signature takes it out")
        XCTAssertNil(model.draft?.automaticSignature)
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "work" }).id)
        XCTAssertEqual(model.draft?.body, "Hi Sam\n\nAlex Morgan\nStudio", "And another puts its own back")
    }

    func testAnEditedSignatureStays() throws {
        let model = makeModel()
        model.startDraft(newDraft(from: "home", address: "alex@home.example", body: "Hi Sam"))
        model.draft?.body = "Hi Sam\n\nAlex (mobile)"
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "work" }).id)
        XCTAssertEqual(model.draft?.body, "Hi Sam\n\nAlex (mobile)")
        XCTAssertEqual(model.draft?.signsAutomatically, false, "Once changed, it is yours")
        XCTAssertEqual(model.draft?.typedBody, "Hi Sam\n\nAlex (mobile)", "All of it counts as your text")
    }

    func testRichTextKeepsItsStylesWhenTheSignatureChanges() throws {
        let model = makeModel()
        model.startDraft(newDraft(from: "home", address: "alex@home.example", body: "Hi"))
        let text = NSMutableAttributedString(string: "Hi\n\nAlex", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 2))
        model.draft?.richText = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
        model.selectSender(try XCTUnwrap(model.senders.first { $0.accountID == "work" }).id)
        XCTAssertEqual(model.draft?.body, "Hi\n\nAlex Morgan\nStudio")
        let rich = MailRichText.attributed(model.draft?.richText, plain: model.draft?.body ?? "")
        XCTAssertEqual(rich.string, "Hi\n\nAlex Morgan\nStudio")
        let font = rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false, "Your bold text stays bold")
    }

    func testADraftOpenedAgainNeverGetsASecondSignature() {
        let model = makeModel()
        model.startDraft(newDraft(from: "home", address: "alex@home.example", body: "Hi"))
        let signed = try! XCTUnwrap(model.draft)
        model.draft = nil
        // As Unsent, a scheduled draft, or a saved draft come back.
        model.startDraft(signed)
        XCTAssertEqual(model.draft?.body, "Hi\n\nAlex")
        model.draft = nil
        // A draft saved before automatic signatures, or one from a server.
        var old = signed
        old.signsAutomatically = nil; old.automaticSignature = nil; old.body = "Hi"
        model.startDraft(old)
        XCTAssertEqual(model.draft?.body, "Hi")
    }

    func testTheSettingTurnsAutomaticSignaturesOff() {
        let suite = "MailSignatureTests." + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: MailSignatures.automaticKey)
        let model = makeModel(defaults: defaults)
        model.startDraft(newDraft(from: "home", address: "alex@home.example", body: "Hi"))
        XCTAssertEqual(model.draft?.body, "Hi")
        model.insertSignature()
        XCTAssertEqual(model.draft?.body, "Hi\n\nAlex", "Insert Signature still adds one by hand")
    }

    // MARK: Composer and layout

    func testFromShowsOnlyWhenThereIsAChoice() {
        XCTAssertFalse(ComposeView.showsFrom(senders: 1, copies: false, hasSender: true))
        XCTAssertTrue(ComposeView.showsFrom(senders: 1, copies: true, hasSender: true), "Cc/Bcc shows it too")
        XCTAssertTrue(ComposeView.showsFrom(senders: 2, copies: false, hasSender: true))
        XCTAssertTrue(ComposeView.showsFrom(senders: 1, copies: false, hasSender: false), "A draft without an account says so")
    }

    func testFormattingKeys() {
        XCTAssertEqual(MailFormattingKey.command(characters: "b", flags: .command), .bold)
        XCTAssertEqual(MailFormattingKey.command(characters: "I", flags: .command), .italic)
        XCTAssertEqual(MailFormattingKey.command(characters: "u", flags: .command), .underline)
        XCTAssertEqual(MailFormattingKey.command(characters: "]", flags: .command), .increaseIndent)
        XCTAssertNil(MailFormattingKey.command(characters: "b", flags: []), "Letters type")
        XCTAssertNil(MailFormattingKey.command(characters: "b", flags: [.command, .shift]))
        XCTAssertNil(MailFormattingKey.command(characters: "v", flags: .command), "Paste stays paste")
    }

    func testTheFormattingBarChoiceIsKept() {
        let suite = "MailSignatureTests." + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MailComposerPreferences(defaults: defaults).showsFormatting, "Hidden by default")
        MailComposerPreferences(defaults: defaults).showsFormatting = true
        XCTAssertTrue(MailComposerPreferences(defaults: defaults).showsFormatting)
        XCTAssertFalse(MailComposerPreferences(defaults: nil).showsFormatting)
    }

    func testDraggedColumnWidthsAreKeptUntilReset() {
        let suite = "MailSignatureTests." + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let page = MailPage(mail: makeModel(), sidebarDefaults: defaults)
        page.dragSidebar(to: 250)
        page.dragList(to: 470, split: .balanced)
        page.keepColumnWidths()
        let again = MailPage(mail: makeModel(), sidebarDefaults: defaults)
        XCTAssertEqual(again.sidebarWidth, 250)
        XCTAssertEqual(again.customListWidth(for: .balanced), 470)
        XCTAssertNil(again.customListWidth(for: .widerMessage), "Another reading setting uses its own width")
        let columns = MailPanelLayout.columns(1320, page: again, split: .balanced)
        XCTAssertEqual(columns.sidebar, 250)
        XCTAssertEqual(columns.list, 470)
        again.resetListWidth(for: .balanced)
        again.resetSidebarWidth()
        let reset = MailPage(mail: makeModel(), sidebarDefaults: defaults)
        XCTAssertNil(reset.sidebarWidth)
        XCTAssertNil(reset.customListWidth(for: .balanced))
        XCTAssertEqual(MailPanelLayout.columns(1320, page: reset, split: .balanced).sidebar, MailPanelLayout.sidebarWidth(1320))
    }

    func testEachLayoutKeepsItsOwnListWidth() {
        let suite = "MailSignatureTests." + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let page = MailPage(mail: makeModel(), sidebarDefaults: defaults)
        page.dragList(to: 470, split: .balanced)
        page.dragList(to: 520, split: .widerMessage)
        page.keepColumnWidths()
        XCTAssertEqual(page.customListWidth(for: .balanced), 470, "Dragging under Wider message keeps Balanced's width")
        let again = MailPage(mail: makeModel(), sidebarDefaults: defaults)
        XCTAssertEqual(again.customListWidth(for: .balanced), 470)
        XCTAssertEqual(again.customListWidth(for: .widerMessage), 520)
        again.resetListWidth(for: .widerMessage)
        XCTAssertEqual(again.customListWidth(for: .balanced), 470, "A reset is for the layout on screen only")
        XCTAssertNil(MailPage(mail: makeModel(), sidebarDefaults: defaults).customListWidth(for: .widerMessage))

        // A width kept by an earlier build counts for the layout it was dragged under.
        let old = "MailSignatureTests." + UUID().uuidString
        let legacy = try! XCTUnwrap(UserDefaults(suiteName: old))
        defer { legacy.removePersistentDomain(forName: old) }
        legacy.set(450.0, forKey: MailReading.legacyListWidthKey)
        legacy.set(MailReading.Split.widerMessage.rawValue, forKey: MailReading.legacyListWidthSplitKey)
        let moved = MailPage(mail: makeModel(), sidebarDefaults: legacy)
        XCTAssertEqual(moved.customListWidth(for: .widerMessage), 450)
        XCTAssertNil(moved.customListWidth(for: .balanced))
    }

    func testTheOutboxNoteShowsOnlyWhenSomethingNeedsReview() {
        let draft = MailModel.Draft(mode: .new, to: "sam@example.com", subject: "Hi")
        func delivery(_ state: MailDelivery.State) -> MailDelivery {
            MailDelivery(id: UUID(), draft: draft, subject: "Hi", recipient: "sam@example.com", date: Date(), state: state, note: nil)
        }
        XCTAssertFalse(MailDeliveryView.needsReview([]))
        XCTAssertFalse(MailDeliveryView.needsReview([delivery(.sent), delivery(.undone), delivery(.appleMailQueued)]))
        XCTAssertTrue(MailDeliveryView.needsReview([delivery(.sent), delivery(.uncertain)]))
        XCTAssertTrue(MailDeliveryView.needsReview([delivery(.failed)]))
    }
}
