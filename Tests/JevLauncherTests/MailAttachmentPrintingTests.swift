import Foundation
import XCTest
@testable import JevLauncher

@MainActor
final class MailAttachmentPrintingTests: XCTestCase {
    func testMissingAttachmentDoesNotCreatePrintOperation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).txt")
        XCTAssertNil(MailAttachmentPrinter.makeOperation(for: url))
    }

    func testTextAttachmentCanBePreparedWithoutShowingPrintUI() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("print-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Printable body".utf8).write(to: url, options: .atomic)
        XCTAssertNotNil(MailAttachmentPrinter.makeOperation(for: url))
    }
}
