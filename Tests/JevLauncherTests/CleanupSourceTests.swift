import AppKit
import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class CleanupSourceTests: XCTestCase {
    private func item(_ pid: Int32, canStop: Bool) -> Cleanup.Item {
        Cleanup.Item(finding: CleanupFinding(group: .computerUse, key: "computer-use:\(pid)", title: "Worker (PID \(pid))",
                                            detail: canStop ? "No parent app" : "Attached to T3 Code; left running",
                                            pids: [pid], memoryMB: 10, checked: false, canStop: canStop))
    }

    private func verbs(_ row: LauncherResult) -> [Verb] {
        if case .thing(let thing) = row.action { return thing.verbs }
        return []
    }

    func testProtectedWorkersHaveNoStopOrIncludeActionAndAreNeverSelected() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stopped: [Int32] = []
        let source = CleanupSource(preferences: Preferences(defaults: defaults), scan: { _ in [self.item(200, canStop: false)] },
                                   stop: { stopped += $0.finding.pids; return "stopped" })
        let rows = try await source.load("")
        XCTAssertEqual(rows.first?.title, "Nothing checked")
        XCTAssertTrue(verbs(rows[0]).isEmpty)
        XCTAssertTrue(verbs(rows[1]).isEmpty)
        XCTAssertEqual(rows[1].symbol, "lock.fill")
        XCTAssertFalse(rows.contains { $0.id == "cleanup:computer-use" })
        XCTAssertTrue(stopped.isEmpty)
    }

    func testGroupStopOnlyIncludesDisconnectedWorkersAndRequiresConfirmation() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stopped: [Int32] = []
        let source = CleanupSource(preferences: Preferences(defaults: defaults),
                                   scan: { _ in [self.item(200, canStop: true), self.item(201, canStop: false)] },
                                   stop: { stopped += $0.finding.pids; return "stopped" })
        let rows = try await source.load("")
        XCTAssertEqual(rows.first?.title, "Nothing checked")
        let group = try XCTUnwrap(rows.first { $0.id == "cleanup:computer-use" })
        let stop = try XCTUnwrap(verbs(group).first)
        XCTAssertTrue(stop.confirm)
        _ = try await stop.run()
        XCTAssertEqual(stopped, [200])
    }

    func testIncludingAWorkerMakesNormalCleanupRequireConfirmation() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = CleanupSource(preferences: Preferences(defaults: defaults), scan: { _ in [self.item(200, canStop: true)] }, stop: { _ in "stopped" })
        let rows = try await source.load("")
        let worker = try XCTUnwrap(rows.first { $0.id == "cleanup:computer-use:200" })
        _ = try await XCTUnwrap(verbs(worker).first).run()
        let checked = try await source.load("")
        XCTAssertTrue(try XCTUnwrap(verbs(checked[0]).first).confirm)
        XCTAssertFalse(verbs(worker).contains { $0.title == "Always Ignore" })
    }

    func testCleanupPageNeedsTwoReturnsAndReloadClearsConfirmation() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false),
                                  keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        var stopped: [Int32] = []
        let source = CleanupSource(preferences: preferences, scan: { _ in [self.item(200, canStop: true)] },
                                   stop: { stopped += $0.finding.pids; return "stopped" })
        let view = SourcePage(.cleanup, source: source, model: model, hasDetail: false, emptyText: "")
        view.reload()
        try await waitFor { !view.rows.isEmpty }
        view.selectedID = "cleanup:computer-use"
        XCTAssertTrue(view.handle(.open(shift: false)))
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertTrue(view.note?.contains("Press Return again") == true)
        view.reload()
        try await waitFor { !view.loading }
        // Yield for the reload even when an existing list keeps `loading` false.
        await Task.yield()
        XCTAssertTrue(view.handle(.open(shift: false)))
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertTrue(view.handle(.open(shift: false)))
        try await waitFor { stopped == [200] }
        view.closed(handingOff: false)
    }

    func testActualStopRefusesAProtectedItemAndAStaleUnknownSelection() async throws {
        let protected = await Cleanup.stop(item(200, canStop: false))
        XCTAssertTrue(protected.contains("protected"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let identity = try XCTUnwrap(CleanupIdentity.read(process.processIdentifier))
        var selected = item(process.processIdentifier, canStop: true)
        selected.identities = [identity]
        let result = await Cleanup.stop(selected)
        XCTAssertTrue(result.contains("left running"))
        XCTAssertTrue(process.isRunning)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testStrictScanCommandAcceptsNoMatchesButRejectsWarningsAndOtherFailures() async throws {
        let empty = try await CommandRunner.capture(["/bin/sh", "-c", "exit 1"], acceptedExitCodes: [0, 1], requireEmptyStderr: true)
        XCTAssertEqual(empty, "")
        for script in ["printf 'warning\\n' >&2; exit 0", "exit 2"] {
            do {
                _ = try await CommandRunner.capture(["/bin/sh", "-c", script], acceptedExitCodes: [0, 1], requireEmptyStderr: true)
                XCTFail("An incomplete scan must fail closed.")
            } catch { }
        }
    }
}
