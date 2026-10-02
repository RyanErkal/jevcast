import AppKit
import XCTest
import LauncherCore
@testable import JevLauncher

/// Skips a test that loads a live `MailModel` when `JEVCAST_SKIP_LIVE_MAIL_MODEL=1`, as CI sets it.
/// GitHub's runner builds with Xcode 26 (Swift 6.3), where these models time out in a test; with
/// Xcode 27 they pass. Run them locally with `swift test`.
func skipLiveMailModelOnCI() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["JEVCAST_SKIP_LIVE_MAIL_MODEL"] == "1",
                  "A live mail model times out with Xcode 26, which CI uses.")
}

/// A mail model over a synthetic index, with a fake send action in place of Apple Mail. Nothing
/// here reaches Mail: sends land in `Outbox`. Message bodies are fake `.emlx` files.
@MainActor
final class MailComposeRig {
    final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [MailModel.Draft] = []
        private var error: Error?
        func add(_ draft: MailModel.Draft) { lock.withLock { items.append(draft) } }
        var all: [MailModel.Draft] { lock.withLock { items } }
        /// The next sends throw this, such as `MailMaybeSentError()`.
        func failing(with error: Error?) { lock.withLock { self.error = error } }
        var failure: Error? { lock.withLock { error } }
    }

    let root: String
    let outbox = Outbox()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-compose-" + UUID().uuidString).path
        try MailFixture.build(root: root, layout: .init(gmailInbox: 5, allMailOnly: 0, sent: 0, trash: 0, exchangeInbox: 0, projects: 0, perFolder: 0))
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    /// Writes a plain-text body for each inbox row, with these headers after From and Subject.
    func writeBodies(rowIDs: [Int64], headers: (Int64) -> String = { _ in "" }) throws {
        let inbox = MailMailbox(rowID: 1, url: "imap://GMAIL-1/INBOX", unread: 0, total: 0)
        for rowID in rowIDs {
            let message = "From: Person \(rowID) <person\(rowID)@example.com>\r\nSubject: Test \(rowID)\r\n" + headers(rowID)
                + "Content-Type: text/plain; charset=utf-8\r\n\r\nHello from message \(rowID).\r\n"
            let data = Data(message.utf8)
            let path = inbox.folder(in: root) + "/" + MailFiles.relativePaths(rowID: rowID)[0]
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try (Data("\(data.count)\n".utf8) + data).write(to: URL(fileURLWithPath: path))
        }
    }

    func model(delay: TimeInterval, quill: @escaping (QuillRequest) async throws -> QuillReply = { _ in throw CancellationError() }) async throws -> MailModel {
        try skipLiveMailModelOnCI()
        let fixtureRoot = root, outbox = outbox
        let model = MailModel(quill: quill, quillAllowed: { true }, statusProvider: { .ready(root: fixtureRoot) },
                              setRead: { _, _, _, _ in },
                              sendDraft: { draft, _ in
                                  outbox.add(draft)
                                  if let error = outbox.failure { throw error }
                              }, undoDelay: delay, draftStore: nil)
        model.senders = [.init(accountID: "GMAIL-1", address: "me@example.com", name: "Me", signature: "")]
        model.refreshStatus()
        try await wait { model.selectedID != nil && !model.isLoading }
        return model
    }

    func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for the mail model", file: file, line: line)
    }

    static func key(_ character: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: flags.contains(.shift) ? character.uppercased() : character,
                         charactersIgnoringModifiers: flags.contains(.shift) ? character.uppercased() : character,
                         isARepeat: false, keyCode: keyCode)!
    }
}
