import Darwin
import XCTest
@testable import LauncherCore

final class ComputerUseCleanupTests: XCTestCase {
    private let home = "/Users/test"
    private let runtime = "/Applications/ChatGPT.app/Contents/Resources/cua_node"

    private func p(_ pid: Int32 = 200, parent: Int32 = 1, path: String? = nil, arguments: [String]? = nil,
                   cpu: Double = 0, seconds: UInt64 = 100, uid: UInt32 = getuid()) -> CleanupProcess {
        let executable = path ?? runtime + "/bin/node"
        let args = arguments ?? [executable, runtime + "/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs"]
        let identity = CleanupIdentity(pid: pid, ppid: parent, uid: uid, startedSeconds: seconds, startedMicroseconds: 20,
                                       path: executable, arguments: args)
        return CleanupProcess(pid: pid, ppid: parent, uid: uid, cpu: cpu, memoryMB: 10, elapsed: 7200, path: executable, identity: identity)
    }

    private func input(_ processes: [CleanupProcess], protected: Set<Int32> = [], launchd: Set<Int32> = [],
                       listening: [Int32: [Int]] = [:]) -> CleanupRules.Input {
        .init(processes: processes, uid: getuid(), listening: listening, launchdPIDs: launchd,
              protectedRoots: protected, ignoredKeys: [], homeDirectory: home)
    }

    private func plan(_ processes: [CleanupProcess]) throws -> CleanupStopPlan {
        let finding = try XCTUnwrap(CleanupRules.find(input(processes)).first)
        return CleanupStopPlan(finding: finding, identities: processes.compactMap(\.identity))
    }

    func testDisconnectedKnownWorkerIsManualAndIncludesOnlyKnownIdleChildren() throws {
        let childPath = runtime + "/bin/node_repl"
        let root = p()
        let child = p(201, parent: 200, path: childPath, arguments: [childPath])
        let finding = try XCTUnwrap(CleanupRules.find(input([root, child])).first)
        XCTAssertEqual(finding.group, .computerUse)
        XCTAssertTrue(finding.canStop)
        XCTAssertFalse(finding.checked)
        XCTAssertEqual(finding.pids, [200, 201])
        XCTAssertEqual(finding.memoryMB, 20)
        XCTAssertEqual(try plan([root, child]).validate(input([root, child]))?.count, 2)
    }

    func testAttachedWorkersAreLockedEvenAtZeroCPU() throws {
        let owner = p(100, path: "/usr/local/bin/codex", arguments: ["codex", "app-server"])
        let root = p(parent: 100)
        let finding = try XCTUnwrap(CleanupRules.find(input([owner, root])).first)
        XCTAssertFalse(finding.canStop)
        XCTAssertFalse(finding.checked)
        XCTAssertTrue(finding.detail.contains("Attached to codex (PID 100)"))
        XCTAssertNil(CleanupStopPlan(finding: finding, identities: [root.identity!]).validate(input([owner, root])))
    }

    func testMissingParentIsUncertainUntilKernelShowsParentOne() throws {
        let finding = try XCTUnwrap(CleanupRules.find(input([p(parent: 100)])).first)
        XCTAssertFalse(finding.canStop)
        XCTAssertTrue(finding.detail.contains("cannot be verified"))
    }

    func testSharedServiceIsNeverStoppable() throws {
        let path = home + "/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"
        let finding = try XCTUnwrap(CleanupRules.find(input([p(path: path, arguments: [path], cpu: 90)])).first)
        XCTAssertFalse(finding.canStop)
        XCTAssertEqual(CleanupRules.find(input([p(path: path, arguments: [path], cpu: 90)])).count, 1)
    }

    func testKnownHistoryClientRequiresExactArguments() {
        let path = home + "/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
        XCTAssertEqual(ComputerUseCleanup.kind(p(path: path, arguments: [path, "computer-history", "mcp"]), home: home), .history)
        XCTAssertNil(ComputerUseCleanup.kind(p(path: path, arguments: [path, "other", "mcp"]), home: home))
    }

    func testLaunchdProtectedListeningBusyAndForeignWorkersStayRunning() throws {
        let cases = [input([p()], launchd: [200]), input([p()], protected: [200]), input([p()], listening: [200: [5000]]), input([p(cpu: 10)])]
        for item in cases {
            let findings = CleanupRules.find(item)
            XCTAssertEqual(findings.count, 1)
            XCTAssertFalse(try XCTUnwrap(findings.first).canStop)
        }
        XCTAssertTrue(CleanupRules.find(input([p(uid: getuid() + 1)])).isEmpty)
    }

    func testAnExecutionWorkerOrUnknownChildBlocksTheWholeFamily() throws {
        for path in [runtime + "/bin/node", "/bin/sleep", "/usr/local/bin/codex"] {
            let child = p(201, parent: 200, path: path, arguments: [path, "kernel.js"])
            let found = CleanupRules.find(input([p(), child]))
            XCTAssertEqual(found.count, 1)
            XCTAssertFalse(try XCTUnwrap(found.first).canStop)
        }
    }

    func testMentioningTheScriptInAnUnrelatedCommandDoesNotMatch() {
        let script = runtime + "/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs"
        XCTAssertNil(ComputerUseCleanup.kind(p(path: "/usr/local/bin/node", arguments: ["node", script]), home: home))
        XCTAssertNil(ComputerUseCleanup.kind(p(arguments: [runtime + "/bin/node", "unrelated.js", script]), home: home))
        XCTAssertNil(ComputerUseCleanup.kind(p(arguments: [runtime + "/bin/node", script, "--unknown"]), home: home))
    }

    func testGenericCleanupCannotStopCodingHostsOrTheirParents() {
        let parent = p(100, path: "/usr/local/bin/node", arguments: ["node", "cli.js"], cpu: 80)
        let host = p(101, parent: 100, path: "/usr/local/bin/codex", arguments: ["codex", "app-server"])
        let child = p(102, parent: 101, path: "/usr/local/bin/node", arguments: ["node", "server.js"], cpu: 90)
        XCTAssertTrue(CleanupRules.find(input([parent, host, child], listening: [100: [5000], 102: [5001]])).isEmpty)
    }

    func testProtectedChildBlocksAnOtherwiseEligibleDevServer() {
        let parent = p(100, path: "/usr/local/bin/node", arguments: ["node", "server.js"])
        let child = p(101, parent: 100, path: "/usr/local/bin/esbuild", arguments: ["esbuild"])
        XCTAssertTrue(CleanupRules.find(input([parent, child], protected: [101], listening: [100: [5000]])).isEmpty)
        XCTAssertTrue(CleanupRules.find(input([parent, child], launchd: [101], listening: [100: [5000]])).isEmpty)
    }

    func testDetachedJavaScriptAgentAndIPCWorkersAreProtectedFromGenericCleanup() {
        for args in [["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
                     ["node", "/usr/local/bin/codex", "app-server"],
                     ["node", "local.cjs", "--ipc-path", "/tmp/test.sock"],
                     ["node", "kernel.js", "--session-id", "test"]] {
            let worker = p(path: "/usr/local/bin/node", arguments: args, cpu: 80)
            XCTAssertTrue(CleanupRules.find(input([worker])).isEmpty)
        }
    }

    func testReusedPIDChangedArgumentsNewWorkAndProtectionInvalidateSelection() throws {
        let root = p()
        let selection = try plan([root])
        XCTAssertNil(selection.validate(input([p(seconds: 101)])))
        XCTAssertNil(selection.validate(input([p(arguments: [runtime + "/bin/node", "different.js"])])))
        XCTAssertNil(selection.validate(input([p(parent: 99)])))
        XCTAssertNil(selection.validate(input([root], protected: [200])))
        XCTAssertNil(selection.validate(input([root, p(201, parent: 200)])))
        XCTAssertNil(selection.validate(input([root, p(201, parent: 200)]), afterTermination: true))
        XCTAssertEqual(selection.validate(input([])), [])
    }

    func testForcePhaseAllowsOnlyTheOriginalReparentedChildren() throws {
        let path = runtime + "/bin/node_repl"
        let root = p()
        let child = p(201, parent: 200, path: path, arguments: [path])
        let selection = try plan([root, child])
        let orphan = p(201, path: path, arguments: [path])
        XCTAssertEqual(selection.validate(input([orphan]), afterTermination: true)?.map(\.pid), [201])
        XCTAssertNil(selection.validate(input([orphan], protected: [201]), afterTermination: true))
        XCTAssertNil(selection.validate(input([orphan], launchd: [201]), afterTermination: true))
        XCTAssertNil(selection.validate(input([orphan, p(202, parent: 201)]), afterTermination: true))
    }

    func testSignalRechecksIdentityAndNeverSignalsReusedOrChangedPID() throws {
        let expected = try XCTUnwrap(p().identity)
        var signals: [(Int32, Int32)] = []
        let send: (Int32, Int32) -> Int32 = { signals.append(($0, $1)); return 0 }
        for changed in [p(seconds: 101).identity, p(parent: 99).identity, p(uid: getuid() + 1).identity, nil] {
            XCTAssertFalse(CleanupStopPlan.signal(expected, read: { _ in changed }, send: send))
        }
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(CleanupStopPlan.signal(expected, read: { _ in expected }, send: send))
        XCTAssertEqual(signals.first?.0, 200)
        XCTAssertEqual(signals.first?.1, SIGTERM)
        XCTAssertFalse(CleanupStopPlan.signal(expected, read: { _ in expected }, send: { _, _ in -1 }))
    }

    func testKernelArgumentParserKeepsEmptyArgumentsAndDoesNotReadEnvironment() {
        var count: Int32 = 4
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array("/bin/test\0\0/bin/test\0a b\0\0last\0SECRET=value\0".utf8)
        XCTAssertEqual(CleanupIdentity.parseArguments(bytes), ["/bin/test", "a b", "", "last"])
        XCTAssertNil(CleanupIdentity.parseArguments(Array(bytes.prefix(10))))
        XCTAssertNil(CleanupIdentity.parseArguments([]))
    }

    func testKernelIdentityAndTerminationOfAnOwnedFixture() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let identity = try XCTUnwrap(CleanupIdentity.read(process.processIdentifier))
        XCTAssertEqual(identity.ppid, getpid())
        XCTAssertEqual(identity.uid, getuid())
        XCTAssertEqual(identity.path, "/bin/sleep")
        XCTAssertEqual(identity.arguments, ["/bin/sleep", "60"])
        XCTAssertTrue(CleanupStopPlan.signal(identity))
        process.waitUntilExit()
        XCTAssertNil(CleanupIdentity.read(process.processIdentifier))
    }
}
