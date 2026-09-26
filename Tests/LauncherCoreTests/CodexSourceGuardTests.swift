import XCTest
@testable import LauncherCore

final class CodexSourceGuardTests: XCTestCase {
    func testStatusReader() {
        XCTAssertEqual(CodexSourceGuard.topLevelStatus("version = 1\nstatus = \"ACTIVE\"\n"), "ACTIVE")
        XCTAssertEqual(CodexSourceGuard.topLevelStatus("status='PAUSED' # note"), "PAUSED")
        XCTAssertNil(CodexSourceGuard.topLevelStatus("status = PAUSED"))
        XCTAssertNil(CodexSourceGuard.topLevelStatus("[meta]\nstatus = \"ACTIVE\""))
    }

    func testBlocksActiveAndUnreadable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNotEqual(CodexSourceGuard.check(path: file.path), .clear)
        try "status = \"ACTIVE\"\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(CodexSourceGuard.check(path: file.path), .clear)
        try "status = \"PAUSED\"\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexSourceGuard.check(path: file.path), .clear)
    }
    func testPromptCannotOverrideRealStatus() {
        let text = "prompt = \"\"\"\nstatus = \"PAUSED\"\n\"\"\"\nstatus = \"ACTIVE\"\n"
        XCTAssertEqual(CodexSourceGuard.topLevelStatus(text), "ACTIVE")
        XCTAssertNil(CodexSourceGuard.topLevelStatus("status = \"PAUSED\"\nstatus = \"ACTIVE\""))
    }

}
