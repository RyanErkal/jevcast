import XCTest
@testable import LauncherCore

final class CleanupTests: XCTestCase {
    private func p(_ pid: Int32, _ ppid: Int32, _ path: String, cpu: Double = 0, mb: Double = 100, hours: Double = 5, uid: UInt32 = 501) -> CleanupProcess {
        CleanupProcess(pid: pid, ppid: ppid, uid: uid, cpu: cpu, memoryMB: mb, elapsed: hours * 3600, path: path)
    }

    func testParsesPsAndElapsed() {
        let rows = CleanupProcess.parse("  812     1   501   0.0  51200 2-03:04:05 /opt/homebrew/bin/node\n 900 812 501 45.2 1024 12:30 /Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)\n")
        XCTAssertEqual(rows.count, 2)
        let expected: TimeInterval = 2 * 86_400 + 3 * 3600 + 4 * 60 + 5
        XCTAssertEqual(rows[0].elapsed, expected)
        XCTAssertEqual(rows[0].memoryMB, 50)
        XCTAssertEqual(rows[1].name, "T3 Code (Nightly)")
        XCTAssertEqual(CleanupProcess.parseElapsed("05:07"), 307)
    }

    func testFindsIdleServersAndLeftoversButKeepsProtectedTrees() {
        let t3 = p(100, 1, "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)", cpu: 10)
        let agentNode = p(101, 100, "/opt/homebrew/bin/node")                 // started by T3: kept
        let agentServer = p(102, 101, "/opt/homebrew/bin/node")               // listening, but under T3: kept
        let idleServer = p(200, 50, "/opt/homebrew/bin/node")                  // idle, listening, over an hour
        let busyServer = p(201, 50, "/opt/homebrew/bin/node", cpu: 12)         // busy: kept
        let youngServer = p(202, 50, "/opt/homebrew/bin/node", hours: 0.5)      // under an hour: kept
        let leftover = p(300, 1, "/opt/homebrew/bin/esbuild", hours: 3)         // no parent, idle, 3 h
        let agentJob = p(301, 1, "/usr/local/bin/python3", hours: 30)           // launchd job: kept
        let system = p(400, 1, "/usr/libexec/trustd", cpu: 50)                  // system: never
        let rootNode = p(500, 1, "/opt/homebrew/bin/node", uid: 0)              // another user: never
        let hot = p(600, 50, "/Applications/Foo.app/Contents/MacOS/Foo", cpu: 80)
        let child = p(201_0, 200, "/opt/homebrew/bin/esbuild", mb: 40)
        let input = CleanupRules.Input(processes: [t3, agentNode, agentServer, idleServer, busyServer, youngServer, leftover, agentJob, system, rootNode, hot, child],
                                       uid: 501, listening: [102: [5173], 200: [3000], 201: [3001], 202: [3002]],
                                       launchdPIDs: [301], protectedRoots: [100], ignoredKeys: [])
        let found = CleanupRules.find(input)
        XCTAssertEqual(found.map(\.group), [.server, .orphan, .heavy])
        XCTAssertEqual(found[0].title, "node on :3000")
        XCTAssertEqual(found[0].pids, [200, 2010], "The server's children go with it.")
        XCTAssertEqual(found[0].memoryMB, 140)
        XCTAssertTrue(found[0].checked)
        XCTAssertEqual(found[1].pids, [300])
        XCTAssertFalse(found[2].checked, "Heavy processes are shown, never checked.")
        let all = Set(found.flatMap(\.pids))
        XCTAssertTrue(all.isDisjoint(with: [100, 101, 102, 201, 202, 301, 400, 500]))
    }

    func testIgnoredKeysAreSkipped() {
        let server = p(200, 50, "/opt/homebrew/bin/node")
        let input = CleanupRules.Input(processes: [server], uid: 501, listening: [200: [3000]], launchdPIDs: [], protectedRoots: [], ignoredKeys: ["server:node:3000"])
        XCTAssertTrue(CleanupRules.find(input).isEmpty)
    }

    func testBootedSimulators() {
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-2":[{"name":"iPhone 17 Pro","udid":"A","state":"Booted"},{"name":"Old","udid":"B","state":"Shutdown"}]}}"#
        let booted = CleanupRules.bootedSimulators(Data(json.utf8))
        XCTAssertEqual(booted.map(\.udid), ["A"])
    }
}
