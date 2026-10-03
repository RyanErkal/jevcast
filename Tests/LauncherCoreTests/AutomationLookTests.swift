import XCTest
@testable import LauncherCore

/// An automation's icon colour, what its run records say about progress, and the words hidden names allow.
final class AutomationLookTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("look-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func sample(_ id: String = "sample-look", accent: String? = nil) -> Automation {
        var a = Automation(id: id, name: "Sample", symbol: "chart.bar.xaxis",
                           kind: .script(ScriptTask(executable: "/bin/echo", workingDirectory: "/")), schedule: Schedule(rule: .manual))
        a.accent = accent
        return a
    }

    func testAccentIsSavedAndOlderFilesStillRead() throws {
        let store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        try store.save(sample(accent: AutomationAccent.red.rawValue))
        let saved = try XCTUnwrap(store.automation(id: "sample-look"))
        XCTAssertEqual(saved.accentChoice, .red)
        XCTAssertEqual(saved.symbol, "chart.bar.xaxis")

        // A file written before the field existed reads, and draws its old colour.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: AutomationJSON.encoder().encode(sample())) as? [String: Any])
        XCTAssertNil(json["accent"], "an unset accent is not written")
        json.removeValue(forKey: "accent")
        let old = try AutomationJSON.decoder().decode(Automation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.accent)
        XCTAssertEqual(old.resolvedAccent, AutomationAccent.fallback(for: "sample-look"))

        // A name from a newer version is kept as written but never drawn.
        json["accent"] = "ultraviolet"
        let newer = try AutomationJSON.decoder().decode(Automation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(newer.accent, "ultraviolet")
        XCTAssertNil(newer.accentChoice)
        XCTAssertEqual(newer.resolvedAccent, AutomationAccent.fallback(for: "sample-look"))
    }

    /// Rows used to pick a colour from the ID with this hash and order. The fallback must give the same one.
    func testFallbackKeepsTheColourRowsAlreadyShowed() {
        let older = ["blue", "indigo", "purple", "pink", "orange", "teal", "green", "cyan", "mint", "brown"]
        for id in ["desktop-tidy-3f9a", "sales-data-demo", "weekly-report-demo", "a", "docs-backup-demo", "x-1-2-3"] {
            let hash = id.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
            XCTAssertEqual(AutomationAccent.fallback(for: id).rawValue, older[Int(hash % 10)], id)
        }
        XCTAssertFalse(AutomationAccent.allCases.prefix(10).contains(.red), "red is only ever chosen, never a fallback")
    }

    func testSymbolNamesAreCheckedForForm() {
        for good in ["gearshape.2", "chart.bar.xaxis", "leaf"] { XCTAssertTrue(AutomationSymbol.isWellFormed(good), good) }
        for bad in ["", "Chart.Bar", "chart bar", ".leaf", "leaf.", "a..b", "../etc", String(repeating: "a", count: 65)] {
            XCTAssertFalse(AutomationSymbol.isWellFormed(bad), bad)
        }
    }

    private func setupSpec(symbol: String? = "chart.bar.xaxis", accent: String?) -> Data {
        var entry: [String: Any] = [
            "id": "sample-look", "name": "Sample",
            "schedule": ["rrule": "FREQ=DAILY;BYHOUR=8;BYMINUTE=0", "timeZone": "Europe/London"],
            "policy": ["timeout": 600, "retries": 0, "catchUp": "skip", "alertOnFailure": true, "alertOnSuccess": false, "keepRuns": 50],
            "script": ["executable": "/bin/echo", "arguments": [], "workingDirectory": "/tmp", "environment": [:], "secretNames": []]
        ]
        if let symbol { entry["symbol"] = symbol }
        if let accent { entry["accent"] = accent }
        return try! JSONSerialization.data(withJSONObject: ["schema": AutomationSetup.schema, "automations": [entry]])
    }

    func testSetupSetsAValidAccentAndKeepsItWhenLeftOut() throws {
        let store = AutomationStore(root: dir.appendingPathComponent("Automations"))
        let first = AutomationSetup.apply(try AutomationSetup.decode(setupSpec(accent: "purple")), store: store, check: false)
        XCTAssertTrue(first.applied, "\(first.problems)")
        XCTAssertEqual(store.automation(id: "sample-look")?.accentChoice, .purple)

        let again = AutomationSetup.apply(try AutomationSetup.decode(setupSpec(accent: nil)), store: store, check: false)
        XCTAssertEqual(again.changes.map(\.kind), [.unchanged], "a file without an accent changes nothing")
        XCTAssertEqual(store.automation(id: "sample-look")?.accentChoice, .purple)

        let unknown = AutomationSetup.apply(try AutomationSetup.decode(setupSpec(accent: "crimson")), store: store, check: false)
        XCTAssertFalse(unknown.applied)
        XCTAssertTrue(unknown.problems.contains { $0.contains("accent") })
        let malformed = AutomationSetup.apply(try AutomationSetup.decode(setupSpec(symbol: "Not A Symbol", accent: nil)), store: store, check: false)
        XCTAssertTrue(malformed.problems.contains { $0.contains("SF Symbol") })
        XCTAssertEqual(store.automation(id: "sample-look")?.accentChoice, .purple, "a refused file writes nothing")
    }

    private func stages(_ entries: [(String, String?, String)]) throws -> Data {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let list = entries.map { RunEngine.StageEntry(stage: $0.0, item: $0.1, state: $0.2, started: start, finished: start,
                                                      detail: "/Users/someone/clients/acme/2026-09.md e3b0c44298fc") }
        return try JSONEncoder.sortedPretty().encode(list)
    }

    func testStageProgressNamesTheLastFinishedStageOnly() throws {
        XCTAssertEqual(StageProgress.parse(try stages([("preflight", nil, "succeeded")])), StageProgress(phrase: "Plan ready"))
        // Planned: item 1 saved earlier (no stage logged), item 2 generated now. Its stages are the only items in the log.
        let mixed = try XCTUnwrap(StageProgress.parse(try stages([
            ("publish", "20260926T080000Z-ab12", "succeeded"), ("preflight", nil, "succeeded"), ("fetch", "acme-monthly", "succeeded")
        ])))
        // Two generated items: the same stage reads the same, whatever came before.
        let two = try XCTUnwrap(StageProgress.parse(try stages([
            ("preflight", nil, "succeeded"), ("fetch", "acme-weekly", "succeeded"), ("analyst", "acme-weekly", "succeeded"),
            ("finish", "acme-weekly", "succeeded"), ("fetch", "acme-monthly", "succeeded")
        ])))
        XCTAssertEqual(mixed, StageProgress(phrase: "Data fetched"))
        XCTAssertEqual(two, mixed, "a position is never inferred from the log")
        for progress in [mixed, two] {
            XCTAssertFalse(progress.phrase.contains { $0.isNumber } || progress.phrase.contains("Item") || progress.phrase.contains("acme"),
                           "no item number, name, or detail: \(progress.phrase)")
        }
        XCTAssertEqual(StageProgress.parse(try stages([("analyst", "x", "failed")]))?.phrase, "Analysis stopped")
        XCTAssertNil(StageProgress.parse(try stages([("upload", nil, "succeeded")])), "an unknown stage is not guessed")
        XCTAssertNil(StageProgress.parse(try stages([])))
        XCTAssertNil(StageProgress.parse(Data("not json".utf8)))
    }

    func testRunRecordsWriteTheStagesTheAppReads() {
        XCTAssertEqual(RunEngine.stagesFile, "stages.json")
        XCTAssertEqual(RunEngine.needsReviewPrefix, "Needs review: ")
        XCTAssertEqual(RunEngine.reportReadyPrefix, "Report ready: ")
    }

    func testReviewIsNeverDoneAndHiddenNamesUseTheCategory() {
        let a = sample()
        var run = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
        run.state = .failed; run.finished = Date(); run.summary = RunEngine.needsReviewPrefix + "Acme weekly"
        XCTAssertTrue(run.needsReview)
        XCTAssertFalse(run.hasReadyReport)
        let hidden = AlertText.make(run, name: "Acme weekly", hideNames: true, category: a.kind.category)
        XCTAssertEqual(hidden, AlertText(title: "Script", message: "It needs your review."))
        XCTAssertEqual(AlertText.make(run, name: "Acme", hideNames: false).message, "Needs review: Acme weekly")
        // The alert rules are unchanged: a review is a failure for whether it alerts at all.
        XCTAssertFalse(AlertDecision.wants(run, policy: Policy(alertOnFailure: false)))
        XCTAssertTrue(AlertDecision.wants(run, policy: Policy()))

        run.state = .succeeded; run.summary = RunEngine.reportReadyPrefix + "Acme weekly"
        XCTAssertFalse(run.needsReview, "only a failed run needs review")
        XCTAssertTrue(run.hasReadyReport)
        XCTAssertEqual(AlertText.make(run, name: "Acme", hideNames: true, category: "Report workflow"),
                       AlertText(title: "Report workflow", message: "A report is ready."))
        XCTAssertEqual(AlertText.make(run, name: "Acme", hideNames: true).title, Automation.Kind.unknownCategory)
    }

    func testLiveIndicatorAlsoShowsAScheduledRetry() {
        var run = RunRecord(id: RunID.make(), automation: sample(), trigger: .schedule, occurrence: nil)
        let now = Date()
        run.started = now.addingTimeInterval(-60)
        let on = AlertSettings(liveRunning: true)
        for state in [RunState.running, .retryWaiting] {
            run.state = state
            XCTAssertEqual(AlertDecision.decideRunning(run, settings: on, now: now), .show, "\(state)")
            XCTAssertEqual(AlertDecision.decideRunning(run, settings: AlertSettings(), now: now), .skip, "off by default")
        }
        for state in [RunState.queued, .needsInput, .failed, .succeeded] {
            run.state = state
            XCTAssertEqual(AlertDecision.decideRunning(run, settings: on, now: now), .skip, "\(state)")
        }
    }

    func testLastSuccessReadsOnlyFinishedSuccesses() {
        let a = sample()
        func run(_ state: RunState, finished: TimeInterval?) -> RunRecord {
            var r = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
            r.state = state; r.finished = finished.map { Date(timeIntervalSince1970: $0) }
            return r
        }
        XCTAssertEqual(RunRecord.lastSuccess(in: [run(.running, finished: nil), run(.failed, finished: 300),
                                                  run(.succeeded, finished: 200), run(.succeeded, finished: 100)]),
                       Date(timeIntervalSince1970: 200))
        XCTAssertNil(RunRecord.lastSuccess(in: [run(.failed, finished: 300), run(.succeeded, finished: nil)]))
    }
}
