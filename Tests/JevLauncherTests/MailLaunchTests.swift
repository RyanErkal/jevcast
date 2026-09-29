import XCTest
import LauncherCore
@testable import JevLauncher

/// Mail starts once at a time, and never while an earlier Mail is still quitting. A fake Mail
/// stands in for the launch steps.
@MainActor
final class MailLaunchTests: XCTestCase {
    @MainActor private final class FakeMail {
        var state = MailLaunch.State.stopped
        /// What a Mail that was quitting is after the wait: stopped, or running when it did not quit.
        var afterQuit = MailLaunch.State.stopped
        var steps: [String] = []
        var openError: Error?
        private var held: [CheckedContinuation<Void, Never>] = []
        private var released = false

        /// Lets every open that is waiting, and every later one, finish.
        func release() { released = true; held.forEach { $0.resume() }; held = [] }

        func launcher() -> MailLaunch {
            MailLaunch(state: { self.state },
                       waitForQuit: { self.steps.append("wait for quit"); self.state = self.afterQuit },
                       open: {
                           self.steps.append("open")
                           if !self.released { await withCheckedContinuation { self.held.append($0) } }
                           if let error = self.openError { self.openError = nil; throw error }
                           self.state = .running
                       })
        }
    }

    func testCallersDuringALaunchShareIt() async throws {
        let mail = FakeMail()
        let launch = mail.launcher()
        let callers = (0..<3).map { _ in Task { try await launch.ensureRunning() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mail.steps, ["open"], "One launch while it is under way")
        mail.release()
        for caller in callers { try await caller.value }
        XCTAssertEqual(mail.state, .running)
        try await launch.ensureRunning()
        XCTAssertEqual(mail.steps, ["open"], "A running Mail is not opened again")
    }

    func testALaunchWaitsUntilAQuittingMailHasEnded() async throws {
        let mail = FakeMail()
        mail.state = .quitting
        mail.release()
        try await mail.launcher().ensureRunning()
        XCTAssertEqual(mail.steps, ["wait for quit", "open"])
        XCTAssertEqual(mail.state, .running)
    }

    func testAMailThatDidNotQuitIsNotOpenedAgain() async throws {
        let mail = FakeMail()
        mail.state = .quitting
        mail.afterQuit = .running
        try await mail.launcher().ensureRunning()
        XCTAssertEqual(mail.steps, ["wait for quit"])
    }

    func testAFailedLaunchCanBeTriedAgain() async throws {
        let mail = FakeMail()
        mail.release()
        mail.openError = LauncherError("Apple Mail is not installed.")
        let launch = mail.launcher()
        do { try await launch.ensureRunning(); XCTFail("The first open fails") } catch {}
        try await launch.ensureRunning()
        XCTAssertEqual(mail.steps, ["open", "open"])
        XCTAssertEqual(mail.state, .running)
    }
}
