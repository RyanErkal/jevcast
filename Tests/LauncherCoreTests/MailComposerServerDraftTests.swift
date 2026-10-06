import XCTest
@testable import LauncherCore

final class MailComposerServerDraftTests: XCTestCase {
    func testServerDraftKeepsBccAndSentRendererDoesNot() {
        var message = OutgoingMessage(from: .init(name: "Me", address: "me@example.com"),
                                      to: [.init(address: "to@example.com")], subject: "Draft", body: "Body")
        message.bcc = [.init(address: "hidden@example.com")]
        let draft = String(decoding: MailComposer.renderServerDraft(message), as: UTF8.self)
        let sent = String(decoding: MailComposer.render(message), as: UTF8.self)
        XCTAssertTrue(draft.contains("\r\nBcc: hidden@example.com\r\n"))
        XCTAssertFalse(sent.contains("\r\nBcc:"))
    }

    func testServerDraftSanitizesIncompleteRecipientHeader() {
        let message = OutgoingMessage(from: .init(address: "me@example.com"), to: [], subject: "Draft", body: "Body")
        let rendered = String(decoding: MailComposer.renderServerDraft(message,
                                                                         toHeader: "unfinished@example.com\r\nX-Injected: yes"), as: UTF8.self)
        XCTAssertTrue(rendered.contains("To: unfinished@example.com  X-Injected: yes"))
        XCTAssertFalse(rendered.contains("\r\nX-Injected:"))
    }
}
