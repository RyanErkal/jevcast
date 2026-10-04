import Darwin
import XCTest
@testable import JevLauncher

/// Tools that would show a second notch panel check the running copy's lock without taking it.
@MainActor final class InstanceGuardTests: XCTestCase {
    func testLockHeldByAnotherOpenFileReadsAsRunning() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JevLauncherTests.\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(InstanceGuard.isHeld(url), "No lock file: nothing runs.")

        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertFalse(InstanceGuard.isHeld(url), "A lock file nobody holds: nothing runs.")

        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(InstanceGuard.isHeld(url))
        XCTAssertTrue(InstanceGuard.isHeld(url), "Checking never takes the lock.")

        flock(fd, LOCK_UN)
        XCTAssertFalse(InstanceGuard.isHeld(url))
    }
}
