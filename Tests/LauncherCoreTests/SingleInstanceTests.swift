import XCTest
@testable import LauncherCore

final class SingleInstanceTests: XCTestCase {
    let app = "/Applications/Jevcast.app/Contents/MacOS/JevLauncher"

    func testOnlyCopyRuns() {
        XCTAssertEqual(SingleInstance.decide(arguments: [app], otherProcesses: 0, lockAcquired: true), .run)
        XCTAssertEqual(SingleInstance.decide(arguments: [app, "--open"], otherProcesses: 0, lockAcquired: true), .run)
    }

    func testSecondCopyHandsOff() {
        XCTAssertEqual(SingleInstance.decide(arguments: [app], otherProcesses: 1, lockAcquired: true), .handOff)
        // A copy from another folder can hold the lock under a different process list.
        XCTAssertEqual(SingleInstance.decide(arguments: [app], otherProcesses: 0, lockAcquired: false), .handOff)
        XCTAssertEqual(SingleInstance.decide(arguments: [app, "--automation-alerts"], otherProcesses: 1, lockAcquired: false), .handOff)
    }

    func testDiagnosticFlagsAlwaysRun() {
        for flag in ["--snapshot-ui", "--diagnose", "--diagnose-mail", "--diagnose-jev", "--capture-automations",
                     "--hyper-led-test", "--notch-demo"] {
            XCTAssertEqual(SingleInstance.decide(arguments: [app, flag, "/tmp/x"], otherProcesses: 2, lockAcquired: false), .diagnostic, flag)
        }
        // Only flags count, not the program path.
        XCTAssertFalse(SingleInstance.isDiagnostic(["--snapshot-ui"]))
    }
}
