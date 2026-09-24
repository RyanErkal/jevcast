import AppKit
import XCTest
@testable import JevLauncher

/// Dictation pastes through the clipboard, then puts the user's clipboard back.
final class TextInserterTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("JevLauncherTests." + UUID().uuidString))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    @MainActor func testPasteMarksTransientAndRestoresClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)
        pasteboard.setString("<b>mine</b>", forType: .html)
        var pasted: String?
        let outcome = TextInserter.insert("dictated", pasteboard: pasteboard, trusted: true,
                                          paste: { pasted = pasteboard.string(forType: .string) }, delay: 50_000_000)
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(pasted, "dictated")
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) ?? false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(pasteboard.string(forType: .string), "mine")
        XCTAssertEqual(pasteboard.string(forType: .html), "<b>mine</b>", "Every type comes back.")
    }

    @MainActor func testSecondPasteBeforeRestoreKeepsTheUsersClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)
        _ = TextInserter.insert("first", pasteboard: pasteboard, trusted: true, paste: {}, delay: 200_000_000)
        _ = TextInserter.insert("second", pasteboard: pasteboard, trusted: true, paste: {}, delay: 50_000_000)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(pasteboard.string(forType: .string), "mine", "Not the first dictation.")
    }

    @MainActor func testNewCopyDuringPasteIsKept() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)
        _ = TextInserter.insert("dictated", pasteboard: pasteboard, trusted: true, paste: {}, delay: 100_000_000)
        pasteboard.clearContents()
        pasteboard.setString("copied later", forType: .string)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied later")
    }

    @MainActor func testWithoutAccessibilityTextStaysOnClipboard() {
        let pasteboard = makePasteboard()
        var pasted = false
        XCTAssertEqual(TextInserter.insert("dictated", pasteboard: pasteboard, trusted: false, paste: { pasted = true }), .onClipboard)
        XCTAssertFalse(pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
    }
}
