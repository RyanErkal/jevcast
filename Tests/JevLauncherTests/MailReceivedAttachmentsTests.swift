import AppKit
import XCTest
import LauncherCore
@testable import JevLauncher

final class MailReceivedAttachmentsTests: XCTestCase {
    private var root: URL!
    private var mailbox: MailMailbox!
    private var message: MailSummary!
    private var raw: Data!
    private var detail: MIMEMessage!
    private var previousBackend: String?

    override func setUpWithError() throws {
        previousBackend = UserDefaults.standard.string(forKey: MailBackend.key)
        UserDefaults.standard.set(MailBackend.appleMail.rawValue, forKey: MailBackend.key)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("received-mail-" + UUID().uuidString, isDirectory: true)
        try MailFixture.build(root: root.path, layout: .init(gmailInbox: 1, allMailOnly: 0, sent: 0, trash: 0, exchangeInbox: 0, projects: 0, perFolder: 0))
        let boxes = try MailStore.mailboxes(root: root.path)
        mailbox = try XCTUnwrap(boxes.first { $0.rowID == 1 })
        message = try XCTUnwrap(MailStore.page(root: root.path, MailModel.query(.inbox, "", boxes)).messages.first)
        raw = Data("""
        From: sender@example.com\r
        Content-Type: multipart/mixed; boundary="parts"\r
        \r
        --parts\r
        Content-Type: text/plain\r
        \r
        hello\r
        --parts\r
        Content-Type: application/octet-stream; name="exact.bin"\r
        Content-Disposition: attachment; filename="exact.bin"\r
        Content-Transfer-Encoding: base64\r
        \r
        AP8K
        --parts--\r
        """.utf8)
        detail = try XCTUnwrap(MIMEMessage.parse(raw))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        if let previousBackend { UserDefaults.standard.set(previousBackend, forKey: MailBackend.key) }
        else { UserDefaults.standard.removeObject(forKey: MailBackend.key) }
    }

    func testLoaderReadsExactBytesFromSyntheticAppleMailStore() async throws {
        try writeEMLX(raw)
        let context = makeContext(message: message)
        let files = try await MailReceivedAttachmentLoader.load(context)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name, "exact.bin")
        XCTAssertEqual(files.first?.data, Data([0, 255, 10]))
    }

    func testMissingBodyReturnsUnavailableWithoutOpeningAppleMail() async throws {
        let context = makeContext(message: message)
        do {
            _ = try await MailReceivedAttachmentLoader.load(context)
            XCTFail("Expected missing body error")
        } catch {
            XCTAssertEqual(error as? MailReceivedAttachmentError, .bodyUnavailable)
        }
    }

    func testChangedMessageIdentityIsRejectedBeforeBodyRead() async throws {
        try writeEMLX(raw)
        let stale = MailSummary(rowID: message.rowID, mailbox: message.mailbox, subject: message.subject,
                                senderName: message.senderName, senderAddress: message.senderAddress, snippet: message.snippet,
                                date: message.date, read: message.read, flagged: message.flagged,
                                conversation: message.conversation, messageKey: "stale-key")
        let context = makeContext(message: stale)
        do {
            _ = try await MailReceivedAttachmentLoader.load(context)
            XCTFail("Expected source changed error")
        } catch {
            XCTAssertEqual(error as? MailReceivedAttachmentError, .sourceChanged)
        }
    }

    func testChangedBodyIsRejectedWithTheReaderDetailStillOpen() async throws {
        let context = makeContext(message: message)
        let changed = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "hello", with: "other").utf8)
        try writeEMLX(changed)
        do {
            _ = try await MailReceivedAttachmentLoader.load(context)
            XCTFail("Expected changed body to be rejected")
        } catch {
            XCTAssertEqual(error as? MailReceivedAttachmentError, .sourceChanged)
        }
    }

    @MainActor
    func testRenderingDoesNotAskModelForSourceOrReadFiles() {
        let calls = LockCounter()
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              statusProvider: { calls.increment(); return .noMail }, draftStore: nil)
        let view = MailReceivedAttachments(model: model, message: message, detail: detail)
        _ = view.body
        XCTAssertEqual(calls.value, 0)
    }

    private func makeContext(message: MailSummary) -> MailReceivedAttachmentContext {
        .init(root: root.path, mailbox: mailbox, message: message, detail: detail, backend: .appleMail,
              indexIdentity: MailStore.FileIdentity(path: MailStore.indexPath(root.path)).map {
                  .init(device: $0.device, inode: $0.inode)
              })
    }

    private func writeEMLX(_ body: Data) throws {
        let file = URL(fileURLWithPath: mailbox.folder(in: root.path)).appendingPathComponent("Data/Messages/\(message.rowID).emlx")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var emlx = Data("\(body.count)\n".utf8); emlx.append(body)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: emlx, attributes: [.posixPermissions: 0o600]))
    }

    private final class LockCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
