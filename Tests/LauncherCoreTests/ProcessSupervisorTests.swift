import XCTest
@testable import LauncherCore

final class ProcessSupervisorTests: XCTestCase {
    func sh(_ script: String, stdin: String = "") -> ProcessLaunch {
        ProcessLaunch(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
                      workingDirectory: "/tmp", stdin: Data(stdin.utf8))
    }

    func testExitStdinLinesAndCwd() {
        var lines: [String] = []
        let lock = NSLock()
        let out = ProcessSupervisor().run(sh("cat; pwd; echo err >&2; exit 3", stdin: "a\nb\n"), timeout: 10) { d in
            lock.lock(); lines.append(String(decoding: d, as: UTF8.self)); lock.unlock()
        }
        XCTAssertEqual(out.reason, .exited)
        XCTAssertEqual(out.exitCode, 3)
        XCTAssertEqual(lines, ["a", "b", "/private/tmp"])
        XCTAssertEqual(String(decoding: out.stderrTail, as: UTF8.self), "err\n")
    }

    func testTimeoutKillsWholeGroup() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        let s = ProcessSupervisor()
        s.killGrace = 1
        let start = Date()
        let out = s.run(sh("sleep 30 & echo $! > '\(marker.path)'; sleep 30"), timeout: 1)
        XCTAssertEqual(out.reason, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        let child = Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        usleep(200_000)
        XCTAssertNotEqual(kill(child, 0), 0, "background child still alive")
        try? FileManager.default.removeItem(at: marker)
    }

    func testTermIgnoredEscalatesToKill() {
        let s = ProcessSupervisor(); s.killGrace = 1
        let out = s.run(sh("trap '' TERM; sleep 30"), timeout: 1)
        XCTAssertEqual(out.reason, .timedOut)
        XCTAssertEqual(out.signal, SIGKILL)
    }

    func testCancel() {
        let s = ProcessSupervisor(); s.killGrace = 1
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { s.cancel() }
        let out = s.run(sh("sleep 30"), timeout: 60)
        XCTAssertEqual(out.reason, .cancelled)
    }

    func testOutputCaps() {
        let s = ProcessSupervisor()
        s.stdoutTailBytes = 1000; s.stderrTailBytes = 100; s.maxLineBytes = 50
        var count = 0
        let out = s.run(sh("head -c 200000 /dev/zero | tr '\\0' 'x'; echo; echo short; head -c 5000 /dev/zero >&2"), timeout: 10) { _ in count += 1 }
        XCTAssertEqual(out.stdoutBytes, 200_007)
        XCTAssertEqual(out.stdoutTail.count, 1000)
        XCTAssertEqual(out.stderrTail.count, 100)
        XCTAssertEqual(count, 1) // the long line is dropped whole
    }

    func testSpawnFailure() {
        let out = ProcessSupervisor().run(ProcessLaunch(executable: "/no/such", arguments: [], environment: [:], workingDirectory: "/tmp", stdin: Data()), timeout: 5)
        if case .spawnFailed = out.reason {} else { XCTFail("\(out.reason)") }
    }
}
