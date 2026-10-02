import AppKit
import SwiftUI
import WebKit
import XCTest
import LauncherCore
@testable import JevLauncher

/// The Apple Mail style composer: its fields, its formatting, and closing it while it is on screen.
@MainActor
final class MailReplyComposerTests: XCTestCase {
    private func reply(all: Bool) throws -> MailModel.Draft {
        let message = try XCTUnwrap(MIMEMessage.parse(Data("""
        From: Sam Lee <sam@example.com>\r
        To: me@example.com, "Smith, Ann" <ann@example.com>\r
        Cc: bob@example.com\r
        Subject: Plans\r
        \r
        Friday?\r
        """.utf8)))
        let summary = MailSummary(rowID: 7, mailbox: 1, subject: "Plans", senderName: "Sam Lee", senderAddress: "sam@example.com",
                                  snippet: "", date: Date(), read: true, flagged: false, conversation: 0)
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, mode: .reply(all: all), subject: "Re: Plans", original: summary,
                                    source: .init(rowID: 7, message: message, html: nil))
        draft.ownAddresses = ["me@example.com"]
        return draft
    }

    func testReplyAllFillsEditableRecipientsWithNamesUntilYouChangeThem() throws {
        var draft = try reply(all: true)
        draft.fillRecipients()
        XCTAssertEqual(draft.to, "Sam Lee <sam@example.com>")
        XCTAssertEqual(draft.cc, "\"Smith, Ann\" <ann@example.com>, bob@example.com", "Your own address stays out; a name with a comma is quoted")
        XCTAssertEqual(try MailActions.contacts(draft.cc).map(\.address), ["ann@example.com", "bob@example.com"])
        draft.cc = "bob@example.com"
        draft.fillRecipients()
        XCTAssertEqual(draft.cc, "bob@example.com", "An edited field is never refilled")
    }

    func testRecipientsAreCheckedForJevcastReplies() throws {
        var draft = try reply(all: false)
        draft.fillRecipients()
        draft.body = "Yes"
        XCTAssertNil(draft.sendProblem)
        draft.bcc = "not an address"
        XCTAssertNotNil(draft.sendProblem)
        draft.bcc = ""
        draft.to = ""
        XCTAssertEqual(draft.sendProblem, "Add a recipient.")
    }

    func testMessageIDUsesTheSendingDomainAndStaysTheSame() throws {
        var draft = try reply(all: false)
        draft.fromAddress = "alex@studio.example"
        XCTAssertTrue(draft.sendingMessageID.hasSuffix("@studio.example>"))
        XCTAssertEqual(draft.sendingMessageID, draft.sendingMessageID)
        XCTAssertEqual(draft.sendingMessageID.dropLast("@studio.example>".count), draft.messageID.dropLast("@jevcast.local>".count))
    }

    func testQuoteChoiceAndBccSurviveSavingWhileOlderDraftsStillLoad() throws {
        var draft = try reply(all: false)
        draft.includesQuote = false
        draft.bcc = "carl@example.com"
        let restored = try JSONDecoder().decode(MailModel.Draft.self, from: JSONEncoder().encode(draft))
        XCTAssertFalse(restored.includesQuote)
        XCTAssertEqual(restored.bcc, "carl@example.com")
        // A draft saved before Bcc and the quote choice existed.
        var older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try reply(all: false))) as! [String: Any]
        older.removeValue(forKey: "bccText"); older.removeValue(forKey: "quoteLeftOut"); older.removeValue(forKey: "filledRecipients")
        let loaded = try JSONDecoder().decode(MailModel.Draft.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertTrue(loaded.includesQuote)
        XCTAssertEqual(loaded.bcc, "")
    }

    func testFormattingReachesTheSentHTML() throws {
        let text = NSMutableAttributedString(string: "Title\nRed struck\nPlain", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
        let centred = NSMutableParagraphStyle(); centred.alignment = .center
        text.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: 6))
        text.addAttribute(.font, value: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 18), toFamily: "Georgia"), range: NSRange(location: 0, length: 5))
        text.addAttributes([.foregroundColor: MailRichText.color(0xd92e29), .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                           range: NSRange(location: 6, length: 10))
        let indented = NSMutableParagraphStyle(); indented.headIndent = 24; indented.firstLineHeadIndent = 24
        text.addAttribute(.paragraphStyle, value: indented, range: NSRange(location: 17, length: 5))
        let rtf = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let html = MailRichText.html(rtf, plain: text.string)
        XCTAssertTrue(html.contains("<div style=\"text-align:center\"><span style=\"font-family:'Georgia',serif;font-size:18px\">Title</span></div>"))
        XCTAssertTrue(html.contains("color:#d92e29"))
        XCTAssertTrue(html.contains("text-decoration:line-through"))
        XCTAssertTrue(html.contains("<div style=\"margin-left:24px\">"))
        XCTAssertEqual(html.components(separatedBy: "color:#").count, 2, "Only the chosen colour; default text has none")
        // Default text after RTF, in dark mode: resolved white must never be written.
        let white = NSAttributedString(string: "Hi", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white])
        let whiteRTF = try white.data(from: NSRange(location: 0, length: 2), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertFalse(MailRichText.html(whiteRTF, plain: "Hi").contains("color:"))
    }

    func testListMarksAreRecognised() {
        XCTAssertEqual(MailEditorCommands.listMarker(in: "•\tItem"), 2)
        XCTAssertEqual(MailEditorCommands.listMarker(in: "12.\tItem"), 4)
        XCTAssertNil(MailEditorCommands.listMarker(in: "Item"))
        XCTAssertNil(MailEditorCommands.listMarker(in: "2024 was good"))
    }

    /// The quote under a reply really renders: the preview builds the HTML that is sent and its
    /// web view shows the attribution and the original's text.
    func testQuotePreviewRendersTheOriginalAsSent() async throws {
        // A live web view in a hosted window, like the live mail models CI skips with Xcode 26.
        try skipLiveMailModelOnCI()
        let message = try XCTUnwrap(MIMEMessage.parse(Data("""
        From: Bodhi <bodhi@example.com>\r
        Subject: Leads\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><h1>Stop Letting Leads Die</h1></body></html>\r
        """.utf8)))
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 3, minute: 1)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: MailQuotePreview(source: .init(rowID: 3, message: message, html: message.html),
                                                                      date: date, forward: false, loadsRemote: false))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var text = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let web = Self.webView(in: window.contentView), !web.isLoading else { continue }
            text = (try? await web.evaluateJavaScript("document.body.innerText") as? String) ?? ""
            if text.contains("Stop Letting Leads Die") { break }
        }
        XCTAssertTrue(text.contains("On 2 Oct 2026, at 03:01, Bodhi <bodhi@example.com> wrote:"), text)
        XCTAssertTrue(text.contains("Stop Letting Leads Die"), text)
    }

    private static func webView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }

    /// Send and Discard set the draft to nil while the editor is still on screen. That used to
    /// force-unwrap the draft in the editor's binding and crash Jevcast.
    func testClosingTheDraftWhileTheComposerIsOnScreenDoesNotCrash() throws {
        try skipLiveMailModelOnCI()
        let model = MailModel(quill: { _ in throw CancellationError() }, quillAllowed: { false }, statusProvider: { .noMail },
                              setRead: { _, _, _, _ in }, sendDraft: { _, _ in }, undoDelay: 5, draftStore: nil)
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, to: "sam@example.com")
        draft.body = "Hello"
        model.draft = draft
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: ComposeView(model: model))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        model.draft = nil
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(model.draft)
    }
}
