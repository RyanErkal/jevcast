import Foundation
import XCTest
@testable import LauncherCore

final class MailServerDraftTests: XCTestCase {
    private var root: URL!
    private var server: FakeIMAPServer!
    private var store: NativeMailStore!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: "/tmp/jevcast-mail-server-drafts-build", isDirectory: true)
        root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        server = FakeIMAPServer(mailboxes: [("INBOX", []), ("Drafts", ["\\Drafts"])])
        store = try NativeMailStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        server = nil
        store = nil
    }

    private var account: NativeMailAccount {
        NativeMailAccount(id: "draft-account", provider: .other, name: "Me", email: "me@example.com",
                          imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
                          smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls),
                          savesSentCopy: false)
    }

    private func makeSync() -> MailAccountSync {
        let server = self.server!
        return MailAccountSync(account: account, store: store,
                               credential: { .password("app-password") },
                               transport: { _, _, _ in server.connect() })
    }

    private func raw(_ id: String, body: String = "") -> Data {
        Data("From: Me <me@example.com>\r\nTo: someone@example.com\r\nBcc: hidden@example.com\r\nSubject: Draft\r\nMessage-ID: \(id)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n".utf8)
    }

    func testSaveReplaceAndRemoveOwnsExactUIDAndPreservesBcc() async throws {
        let sync = makeSync()
        let first = raw("<draft-one@example.com>", body: "one")
        let firstReference = try await sync.saveServerDraft(first, messageID: "<draft-one@example.com>")
        XCTAssertEqual(server.mailbox("Drafts")?.messages.count, 1)
        XCTAssertEqual(server.mailbox("Drafts")?.messages.first?.raw, first)
        XCTAssertTrue(server.mailbox("Drafts")?.messages.first?.flags.contains("\\Draft") == true)

        let second = raw("<draft-two@example.com>", body: "two")
        let secondReference = try await sync.saveServerDraft(second, messageID: "<draft-two@example.com>", replacing: firstReference)
        XCTAssertNotEqual(firstReference.uid, secondReference.uid)
        XCTAssertEqual(server.mailbox("Drafts")?.messages.map(\.uid), [secondReference.uid])
        XCTAssertEqual(server.mailbox("Drafts")?.messages.first?.raw, second)
        XCTAssertTrue(String(decoding: server.mailbox("Drafts")!.messages.first!.raw, as: UTF8.self).contains("Bcc: hidden@example.com"))

        try await sync.removeServerDraft(secondReference)
        XCTAssertTrue(server.mailbox("Drafts")?.messages.isEmpty == true)
        await sync.stop()
    }

    func testChangedDraftIsNeverRemoved() async throws {
        let sync = makeSync()
        let original = raw("<draft-three@example.com>", body: "original")
        let reference = try await sync.saveServerDraft(original, messageID: "<draft-three@example.com>")
        server.mailbox("Drafts")?.messages[0].raw = raw("<draft-three@example.com>", body: "edited elsewhere")

        do {
            try await sync.removeServerDraft(reference)
            XCTFail("an externally edited draft must not be removed")
        } catch MailServerDraftError.ownedDraftChanged(let changed) {
            XCTAssertEqual(changed, reference)
        }
        XCTAssertEqual(server.mailbox("Drafts")?.messages.count, 1)
        await sync.stop()
    }

    func testUIDPlusIsRequiredBeforeAppend() async throws {
        server.capabilities.removeAll { $0 == "UIDPLUS" }
        let sync = makeSync()
        do {
            _ = try await sync.saveServerDraft(raw("<draft-four@example.com>"), messageID: "<draft-four@example.com>")
            XCTFail("UIDPLUS is required")
        } catch MailServerDraftError.uidPlusRequired {}
        XCTAssertEqual(server.commands("APPEND"), 0)
        XCTAssertTrue(server.mailbox("Drafts")?.messages.isEmpty == true)
        await sync.stop()
    }
}
