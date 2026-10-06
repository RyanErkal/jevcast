import Foundation
import XCTest
@testable import LauncherCore

final class MailReceivedAttachmentsTests: XCTestCase {
    func testExtractionKeepsAttachmentBytesExactly() throws {
        let bytes = Data([0, 1, 2, 255, 10, 13])
        let encoded = bytes.base64EncodedString()
        let raw = Data("""
        From: sender@example.com
        Content-Type: multipart/mixed; boundary="parts"

        --parts
        Content-Type: text/plain

        hello
        --parts
        Content-Type: application/octet-stream; name="raw.bin"
        Content-Disposition: attachment; filename="raw.bin"
        Content-Transfer-Encoding: base64

        \(encoded)
        --parts--
        """.utf8)
        let detail = try XCTUnwrap(MIMEMessage.parse(raw))
        let files = try MailReceivedAttachmentExtractor.extract(rawMessage: raw, expected: detail)
        XCTAssertEqual(files.map(\.name), ["raw.bin"])
        XCTAssertEqual(files.first?.data, bytes)
    }

    func testRFC2231FilenameIsDecodedAndUnsafePathIsReducedToFinalComponent() throws {
        let raw = Data("""
        Content-Type: application/octet-stream; name*=utf-8''r%C3%A9sum%C3%A9.pdf
        Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf

        bytes
        """.utf8)
        let detail = try XCTUnwrap(MIMEMessage.parse(raw))
        XCTAssertEqual(detail.attachments.first?.name, "résumé.pdf")
        let file = try XCTUnwrap(MailReceivedAttachmentExtractor.extract(rawMessage: raw, expected: detail).first)
        XCTAssertEqual(file.name, "résumé.pdf")
        XCTAssertEqual(MailReceivedAttachmentExtractor.safeFilename("../../résumé.pdf"), "résumé.pdf")
        XCTAssertEqual(MailReceivedAttachmentExtractor.safeFilename(".."), "attachment")
    }

    func testDuplicateNamesAreUniqueAndKeepExtensions() {
        XCTAssertEqual(MailReceivedAttachmentExtractor.uniqueFilenames(["report.pdf", "report.pdf", "REPORT.PDF", "notes"]),
                       ["report.pdf", "report (2).pdf", "REPORT (3).PDF", "notes"])
    }

    func testChangedMessageTextWithUnchangedAttachmentMetadataIsRejected() throws {
        let raw = Data("""
        Message-ID: <attachment@example.com>
        Content-Type: multipart/mixed; boundary="parts"

        --parts
        Content-Type: text/plain

        before
        --parts
        Content-Type: application/octet-stream; name="file.bin"
        Content-Disposition: attachment; filename="file.bin"
        Content-Transfer-Encoding: base64

        AQID
        --parts--
        """.utf8)
        let expected = try XCTUnwrap(MIMEMessage.parse(raw))
        let changed = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "before", with: "after!").utf8)
        XCTAssertEqual(MIMEMessage.parse(changed)?.attachments, expected.attachments)
        XCTAssertThrowsError(try MailReceivedAttachmentExtractor.extract(rawMessage: changed, expected: expected)) {
            XCTAssertEqual($0 as? MailReceivedAttachmentError, .sourceChanged)
        }
    }

    func testLongFilenameAndExtensionRemainWithinFilesystemLimit() {
        for name in [String(repeating: "é", count: 300) + ".pdf", "file." + String(repeating: "x", count: 300)] {
            let safe = MailReceivedAttachmentExtractor.safeFilename(name)
            XCTAssertLessThanOrEqual(safe.utf8.count, 240)
            XCTAssertFalse(safe.contains("/"))
        }
    }

    func testMetadataMismatchRefusesStaleSource() throws {
        let raw = Data("not a MIME message".utf8)
        let expected = MIMEMessage(headers: [("Content-Type", "application/pdf")], attachments: [.init(name: "report.pdf", mimeType: "application/pdf", size: 3)])
        XCTAssertThrowsError(try MailReceivedAttachmentExtractor.extract(rawMessage: raw, expected: expected)) { error in
            XCTAssertEqual(error as? MailReceivedAttachmentError, .malformedMessage)
        }
    }

    func testStagingUsesOwnerOnlyDirectoryAndCleansUp() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("received-attachments-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let staging = try MailReceivedAttachmentStaging(parent: parent)
        let items = try staging.stage([
            .init(name: "../a.txt", mimeType: "text/plain", data: Data("one".utf8)),
            .init(name: "a.txt", mimeType: "text/plain", data: Data("two".utf8))
        ])
        XCTAssertEqual(items.map(\.name), ["a.txt", "a (2).txt"])
        XCTAssertTrue(items.allSatisfy { (try? Data(contentsOf: $0.url)) != nil })
        let directoryMode = try FileManager.default.attributesOfItem(atPath: staging.directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode.map { Int16(truncating: $0) & 0o777 }, 0o700)
        let fileMode = try FileManager.default.attributesOfItem(atPath: items[0].url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode.map { Int16(truncating: $0) & 0o777 }, 0o600)
        let directory = staging.directory
        staging.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStagingRefusesExistingSymlink() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("received-attachments-symlink-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let staging = try MailReceivedAttachmentStaging(parent: parent)
        let target = parent.appendingPathComponent("outside")
        try Data("must stay empty".utf8).write(to: target)
        let link = staging.directory.appendingPathComponent("safe.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try staging.stage([.init(name: "safe.txt", mimeType: "text/plain", data: Data("changed".utf8))]))
        XCTAssertEqual(try Data(contentsOf: target), Data("must stay empty".utf8))
    }
}
