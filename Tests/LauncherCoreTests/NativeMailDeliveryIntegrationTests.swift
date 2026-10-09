import XCTest
@testable import LauncherCore

/// The composer supplies one verified sender to every native delivery variant. These fixtures
/// prove that the selected alias is the From address while the account remains the SMTP owner.
final class NativeMailDeliveryIntegrationTests: XCTestCase {
    private var root: URL!
    private var server: FakeIMAPServer!
    private var smtp: FakeSMTPServer!
    private var store: NativeMailStore!
    private var reader: MailDatabase!

    private let account = NativeMailAccount(id: "delivery-account", provider: .yahoo, name: "Me",
                                            email: "me@example.com",
                                            imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
                                            smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-delivery-" + UUID().uuidString,
                                                                               isDirectory: true)
        server = FakeIMAPServer(mailboxes: [("INBOX", []), ("Archive", ["\\Archive"])])
        smtp = FakeSMTPServer()
        store = try NativeMailStore(root: root)
        reader = try MailDatabase(path: NativeMailStore.indexPath(root: root))
        server.deliver(to: "INBOX", subject: "Question", from: "Sam <sam@example.com>", body: "Are you free?",
                       messageID: "<question@example.com>")
    }

    override func tearDownWithError() throws {
        reader = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testAliasIsPassedToNewReplyAndForwardWithCanonicalSMTPEnvelope() async throws {
        let imap = server!
        let outgoing = smtp!
        let engine = NativeMailEngine(store: store, credential: { _ in .password("app-password") },
                                      transport: { host, _, _ in host.hasPrefix("smtp") ? outgoing.connect() : imap.connect() })
        await engine.setAccounts([account])

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try reader.rows("SELECT COUNT(*) FROM messages").first?.first?.int == 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let row = try XCTUnwrap(reader.rows("SELECT ROWID FROM messages LIMIT 1").first?.first?.int)
        let sender = NativeMailSender(address: "sales@example.com", name: "Sales", accountAddress: account.email,
                                      providerAuthorized: true)

        try await engine.send(from: account.id, to: ["ann@example.com"], cc: [], subject: "New", body: "Hello",
                              sender: sender)
        try await engine.reply(to: row, text: "Yes", all: false, from: account.id, quote: false, sender: sender)
        try await engine.forward(row, text: "FYI", to: ["bob@example.com"], from: account.id, sender: sender)

        let deliveries = outgoing.delivered
        XCTAssertEqual(deliveries.count, 3)
        for delivery in deliveries {
            XCTAssertEqual(delivery.from, "<" + account.email + ">", "SMTP envelope must stay with the credential owner")
            let message = try XCTUnwrap(MIMEMessage.parse(delivery.data))
            XCTAssertEqual(MailAddress.list(message.header("From") ?? "").first?.address, sender.address)
            XCTAssertEqual(MailAddress.list(message.header("From") ?? "").first?.name, sender.name)
        }
        await engine.stopAll()
    }
}
