import Foundation
import XCTest
@testable import LauncherCore

final class MailArchiveTests: XCTestCase {
    private var root: URL!
    private var sourceRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-archive-" + UUID().uuidString, isDirectory: true)
        sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mail-archive-input-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: sourceRoot)
    }

    func testEMLRoundTripPreservesRawBytesAndAttachments() throws {
        var outgoing = OutgoingMessage(from: .init(address: "sender@example.com"), to: [.init(address: "reader@example.com")], subject: "Archive", body: "Hello")
        outgoing.attachments = [.init(filename: "report.pdf", mimeType: "application/pdf", data: Data([0, 1, 2, 255]))]
        let raw = MailComposer.render(outgoing)
        let input = sourceRoot.appendingPathComponent("message.eml")
        try raw.write(to: input)

        let store = try MailArchiveStore(root: root)
        let preview = try store.preview(url: input)
        XCTAssertEqual(preview.messages.count, 1)
        XCTAssertEqual(preview.messages[0].attachments.map(\.name), ["report.pdf"])
        let result = try store.importArchive(url: input, preview: preview)
        let message = try XCTUnwrap(result.imported.first)
        XCTAssertEqual(try store.rawMessage(for: message.id), raw)
        XCTAssertEqual(MIMEMessage.files(raw).first?.data, Data([0, 1, 2, 255]))
    }

    func testMboxFromLinesEscapeAndRoundTrip() throws {
        let raw = Data("From: sender@example.com\r\nSubject: From lines\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nFrom ordinary\r\n>From already quoted\r\n".utf8)
        let store = try MailArchiveStore(root: root)
        let destination = sourceRoot.appendingPathComponent("roundtrip.mbox")
        _ = try store.exportNative(rawMessages: [raw], format: .mbox, to: destination)
        let exported = try Data(contentsOf: destination)
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains(">From ordinary"))
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains(">>From already quoted"))

        let importedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mail-archive-roundtrip-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: importedRoot) }
        let imported = try MailArchiveStore(root: importedRoot)
        let preview = try imported.preview(url: destination)
        XCTAssertEqual(preview.messages.count, 1)
        let result = try imported.importArchive(url: destination, preview: preview)
        XCTAssertEqual(try imported.rawMessage(for: XCTUnwrap(result.imported.first).id), raw)
    }

    func testDuplicateDigestIsReportedInPreviewAndImport() throws {
        let raw = Data("From: sender@example.com\r\nSubject: Same\r\n\r\nBody\r\n".utf8)
        let first = sourceRoot.appendingPathComponent("first.eml")
        let second = sourceRoot.appendingPathComponent("second.eml")
        try raw.write(to: first); try raw.write(to: second)
        let store = try MailArchiveStore(root: root)
        _ = try store.importArchive(url: first)
        XCTAssertEqual(store.messages(matching: "Body").count, 1, "Search includes the local message body.")
        let preview = try store.preview(url: second)
        XCTAssertEqual(preview.duplicateCount, 1)
        XCTAssertTrue(preview.messages[0].duplicate)
        let result = try store.importArchive(url: second, preview: preview)
        XCTAssertEqual(result.imported.count, 0)
        XCTAssertEqual(result.duplicateCount, 1)
    }

    func testCorruptIndexIsNotReplaced() throws {
        _ = try MailArchiveStore(root: root)
        let index = root.appendingPathComponent("index.json")
        try Data("{not-json".utf8).write(to: index)
        XCTAssertThrowsError(try MailArchiveStore(root: root)) { error in
            XCTAssertEqual(error as? MailArchiveError, .corruptIndex)
        }
        XCTAssertEqual(try Data(contentsOf: index), Data("{not-json".utf8))
    }

    func testMboxPartialFailureImportsValidMessagesAndReportsMalformedMessage() throws {
        let valid = "From: sender@example.com\r\nSubject: Good\r\n\r\nBody\r\n"
        let input = sourceRoot.appendingPathComponent("partial.mbox")
        let mbox = "From sender@example.com Thu Jan 1 00:00:00 2026\n" + valid + "\n" +
            "From broken@example.com Thu Jan 1 00:00:01 2026\nnot an email\n"
        try Data(mbox.utf8).write(to: input)
        let store = try MailArchiveStore(root: root)
        let preview = try store.preview(url: input)
        XCTAssertEqual(preview.messages.count, 1)
        XCTAssertTrue(preview.errors.contains { $0.kind == .malformedMessage })
        let result = try store.importArchive(url: input, preview: preview)
        XCTAssertEqual(result.imported.count, 1)
        XCTAssertTrue(result.errors.contains { $0.kind == .malformedMessage })
    }

    func testUnsafeSourceDestinationAndNamesDoNotTraversePaths() throws {
        let raw = Data("From: sender@example.com\r\nSubject: Safe\r\n\r\nBody\r\n".utf8)
        let actual = sourceRoot.appendingPathComponent("actual.eml")
        try raw.write(to: actual)
        let link = sourceRoot.appendingPathComponent("link.eml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        let store = try MailArchiveStore(root: root)
        XCTAssertThrowsError(try store.preview(url: link)) { error in XCTAssertEqual(error as? MailArchiveError, .unsafeSource) }
        XCTAssertEqual(MailArchiveStore.safeFilename("../../private/secret.txt"), "secret.txt")

        let realFolder = sourceRoot.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: false)
        let folderLink = sourceRoot.appendingPathComponent("folder-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: realFolder)
        let destination = folderLink.appendingPathComponent("out.mbox")
        XCTAssertThrowsError(try store.exportNative(rawMessages: [raw], format: .mbox, to: destination)) { error in
            XCTAssertEqual(error as? MailArchiveError, .unsafeDestination)
        }
    }

    func testSizeLimitsAndSavePanelOverwriteBoundaryAreEnforced() throws {
        let raw = Data("From: sender@example.com\r\nSubject: Limited\r\n\r\nBody\r\n".utf8)
        let input = sourceRoot.appendingPathComponent("limited.eml")
        try raw.write(to: input)
        let limited = try MailArchiveStore(root: root, limits: .init(maxInputBytes: 1024, maxMessageBytes: 12))
        let preview = try limited.preview(url: input)
        XCTAssertTrue(preview.messages.isEmpty)
        XCTAssertTrue(preview.errors.contains { $0.kind == .messageTooLarge })

        let output = sourceRoot.appendingPathComponent("existing.eml")
        try Data("existing".utf8).write(to: output)
        let normal = try MailArchiveStore(root: sourceRoot.appendingPathComponent("normal-store"))
        XCTAssertThrowsError(try normal.exportNative(rawMessages: [raw], format: .eml, to: output)) { error in
            XCTAssertEqual(error as? MailArchiveError, .destinationExists)
        }
    }
}
