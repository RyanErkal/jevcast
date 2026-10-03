import AppKit
import XCTest
import LauncherCore
@testable import JevLauncher

/// The notch's look for automations: icon and colour, the running card's facts, several runs at once,
/// review priority, and what hidden names keep off the screen.
final class NotchLookTests: XCTestCase {
    private func automation(_ id: String = "acme-weekly-1a2b", name: String = "Acme Client Weekly", staged: Bool = true,
                            accent: AutomationAccent? = .red) -> Automation {
        let script = ScriptTask(executable: "/bin/echo", workingDirectory: "/Users/someone/clients/acme")
        let kind: Automation.Kind = staged
            ? .staged(StagedTask(preflight: script, finish: script, analyst: AgentTask(prompt: "", workingDirectory: "/"), claim: "acme"))
            : .script(script)
        var a = Automation(id: id, name: name, symbol: "chart.bar.xaxis", kind: kind, schedule: Schedule(rule: .manual))
        a.accent = accent?.rawValue
        return a
    }

    private func run(_ a: Automation, _ state: RunState, summary: String = "", error: String? = nil) -> RunRecord {
        var r = RunRecord(id: RunID.make(), automation: a, trigger: .schedule, occurrence: nil)
        r.state = state; r.summary = summary; r.error = error
        r.started = Date().addingTimeInterval(-90)
        if state.isFinished || state.needsUser { r.finished = Date() }
        return r
    }

    private func running(_ id: String, symbol: String = "gearshape.2", accent: String? = nil) -> NotchAlert {
        NotchAlert(id: "running:\(id)/r", kind: .running, symbol: symbol, accent: accent, title: id, message: "Running",
                   actions: [.init("Details", id: NotchAlert.detailsAction),
                             .init("Cancel Run", id: "cancel", role: .destructive, menuOnly: true)],
                   automationID: id, runID: "r")
    }

    // MARK: The running card

    func testRunningCardShowsTheLastFinishedStageAndKeepsCancelInTheMenu() {
        let a = automation()
        var r = run(a, .running, summary: "Which folder should it use?")
        let plain = AutomationCenter.runningAlert(r, automation: a, hideNames: false)
        XCTAssertNil(plain.detail, "a summary left from a question is not a current step")
        XCTAssertEqual(plain.presentation.runningLine(now: Date()), "Running", "no placeholder, only an honest generic line")
        XCTAssertEqual(plain.presentation.visibleActions.map(\.id), [NotchAlert.detailsAction])
        XCTAssertEqual(plain.presentation.overflowActions.map(\.id), ["cancel"])
        XCTAssertEqual(plain.presentation.overflowActions.first?.role, .destructive)
        XCTAssertEqual(plain.symbol, "chart.bar.xaxis")
        XCTAssertEqual(plain.accent, "red")

        let now = r.started!.addingTimeInterval(84)
        let staged = AutomationCenter.runningAlert(r, automation: a, hideNames: false,
                                                   progress: StageProgress(phrase: "Data fetched"),
                                                   lastSuccess: now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(staged.presentation.runningLine(now: now), "Data fetched", "the stage alone, never an item position")
        XCTAssertEqual(NotchRunningMeta.line(staged.presentation, now: now), "1:24 · Last success 3h ago")
        XCTAssertEqual(NotchRunningMeta.line(staged.presentation, now: now, spoken: true), "1:24 elapsed · Last success 3h ago")

        r.attempt = 2
        XCTAssertEqual(AutomationCenter.runningAlert(r, automation: a, hideNames: false).presentation.runningLine(now: now),
                       "Running · attempt 2")
    }

    func testRetryShowsOnlyFactsTheRecordHas() {
        let a = automation()
        let r = run(a, .retryWaiting, error: "Could not start /Users/someone/bin/tool")
        let alert = AutomationCenter.runningAlert(r, automation: a, hideNames: false)
        XCTAssertEqual(alert.id, AutomationCenter.runningAlertID(r), "the same card as while running, updated in place")
        XCTAssertEqual(alert.retry, NotchAlert.Retry(attempt: 1, at: nil), "records carry no retry time, so none is shown")
        let p = alert.presentation
        XCTAssertEqual(p.runningLine(now: Date()), "Retrying automatically · attempt 1 failed")
        XCTAssertEqual(NotchStyle.statusText(p), "Retrying")
        XCTAssertFalse(p.runningLine(now: Date()).contains("/Users"), "the error stays in Details")
        // A demo fixture may give a time; then the line counts down, and never below zero.
        var timed = p; timed.retry?.at = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(timed.runningLine(now: Date(timeIntervalSince1970: 960)), "Retrying in 0:40 · attempt 1 failed")
        XCTAssertEqual(timed.runningLine(now: Date(timeIntervalSince1970: 1_001)), "Retrying automatically · attempt 1 failed")
    }

    // MARK: Hidden names

    /// Every state's words with names hidden: the category, fixed sentences, and no name, path, or hash.
    func testHiddenNamesShowCategoryIconAndColourOnly() {
        let a = automation()
        let secrets = ["Acme", "acme", "/Users", ".md", "e3b0c442", "Weekly"]
        let runs = [
            run(a, .needsInput), run(a, .needsApproval),
            run(a, .failed, summary: "Failed reading /Users/someone/clients/acme/2026-09.md", error: "e3b0c442 mismatch"),
            run(a, .failed, summary: RunEngine.needsReviewPrefix + "Acme Weekly 2026-09"),
            run(a, .interrupted, error: "/Users/someone/clients/acme"),
            run(a, .succeeded, summary: RunEngine.reportReadyPrefix + "Acme Weekly 2026-09.md")
        ]
        var alerts = runs.map { AutomationCenter.makeAlert($0, automation: a, hideNames: true) }
        alerts.append(AutomationCenter.runningAlert(run(a, .running, summary: "Reading /Users/someone/clients/acme"), automation: a,
                                                    hideNames: true, progress: StageProgress(phrase: "Plan ready")))
        for alert in alerts {
            let p = alert.presentation
            // The island's accessibility label is built from these same fields.
            let spoken = "\(p.title). \(p.message)\(p.detail.map { ". " + $0 } ?? "")"
            for secret in secrets { XCTAssertFalse(spoken.contains(secret), "\(alert.kind) shows \(secret): \(spoken)") }
            XCTAssertEqual(alert.title, "Report workflow")
            XCTAssertEqual(alert.symbol, "chart.bar.xaxis", "the chosen icon stays")
            XCTAssertEqual(alert.accent, "red", "the chosen colour stays")
        }
        XCTAssertEqual(alerts[3].kind, .review)
        XCTAssertEqual(alerts[5].message, "A report is ready.")
        XCTAssertTrue(alerts[0].choices.isEmpty && !alerts[0].allowsReply)
    }

    func testAMissingSymbolOrAutomationStillDrawsAnIcon() {
        var a = automation(accent: nil)
        a.symbol = "no.such.symbol.anywhere"
        let r = run(a, .failed)
        let alert = AutomationCenter.makeAlert(r, automation: a, hideNames: false)
        XCTAssertEqual(alert.symbol, AutomationSymbol.fallback)
        XCTAssertEqual(alert.accent, AutomationAccent.fallback(for: a.id).rawValue)
        let orphan = AutomationCenter.makeAlert(r, automation: nil, hideNames: true)
        XCTAssertEqual(orphan.title, Automation.Kind.unknownCategory)
        XCTAssertEqual(orphan.accent, AutomationAccent.fallback(for: a.id).rawValue)
    }

    // MARK: Review, report, and failure

    func testReviewLeadsWithReviewAndIsNeverDone() {
        let a = automation()
        let review = AutomationCenter.makeAlert(run(a, .failed, summary: RunEngine.needsReviewPrefix + "Weekly"), automation: a, hideNames: false)
        XCTAssertEqual(review.kind, .review)
        XCTAssertEqual(review.tone, .attention)
        XCTAssertEqual(review.actions.map(\.id), ["review", "later"])
        XCTAssertFalse(review.actions.contains { $0.id == "retry" }, "a retry would stop at the same place")
        XCTAssertNotEqual(NotchStyle.statusText(review.presentation), "Done")
        XCTAssertEqual(NotchBadge.symbol(review.presentation.phase), "eye.fill")

        let ready = AutomationCenter.makeAlert(run(a, .succeeded, summary: RunEngine.reportReadyPrefix + "Weekly"), automation: a, hideNames: false)
        XCTAssertEqual(ready.kind, .success)
        XCTAssertEqual(ready.actions.first?.title, "Open")
        let failed = AutomationCenter.makeAlert(run(a, .failed, error: "boom"), automation: a, hideNames: false)
        XCTAssertEqual(failed.actions.map(\.title), ["Retry", "Details", "Dismiss"])
    }

    @MainActor func testReviewOutranksRunningAndFailureAndWaitsForTheUser() {
        var q = NotchQueue()
        q.add(running("one")); q.add(running("two"))
        q.add(NotchAlert(id: "run:f/1", kind: .failure, symbol: "x", title: "f", message: "m", runID: "1"))
        q.add(NotchAlert(id: "run:v/2", kind: .review, symbol: "x", title: "v", message: "m", runID: "2"))
        XCTAssertEqual(q.visible.map(\.alert.id), ["run:v/2", "run:f/1"], "running never hides work that needs the user")
        XCTAssertEqual(q.presentation?.title, "2 automations need you")
        XCTAssertNil(NotchTiming.seconds(for: .review, failureSeconds: 8), "a review stays until handled")
        XCTAssertEqual(NotchAlertController.restingMode(for: q.presentation!), .card)
    }

    // MARK: Several running

    @MainActor func testSeveralRunningShowBoundedDistinctIconsAndOneDetailsEach() {
        var q = NotchQueue()
        let alerts = [running("a", symbol: "chart.bar.xaxis", accent: "purple"), running("b", symbol: "externaldrive", accent: "teal"),
                      running("c", symbol: "chart.bar.xaxis", accent: "purple"), running("d", symbol: "folder", accent: "red"),
                      running("e", symbol: "bolt", accent: "green")]
        for alert in alerts { q.add(alert) }
        let shown = try! XCTUnwrap(q.presentation)
        let p = shown.presentation
        XCTAssertTrue(p.isRunningStack)
        XCTAssertEqual(p.stackCount, 5, "the count gives the total")
        XCTAssertEqual(p.identities.map(\.symbol), ["chart.bar.xaxis", "externaldrive", "folder"],
                       "at most three, each look once, in arrival order")
        XCTAssertEqual(NotchAlertController.restingMode(for: shown), .pill)
        for member in shown.stack {
            XCTAssertEqual(member.presentation.rowActions.map(\.id), [NotchAlert.detailsAction])
            XCTAssertEqual(member.presentation.rowMenu.map(\.id), ["cancel"])
        }

        // A timeline update replaces each card in place: no duplicates, same order.
        for var alert in alerts { alert.detail = "Plan ready"; q.add(alert) }
        XCTAssertEqual(q.entries.count, 5)
        XCTAssertEqual(q.presentation?.stack.map(\.id), alerts.map(\.id))
        XCTAssertEqual(q.presentation?.id, NotchQueue.stackID, "the stack keeps one identity while it changes")

        // A run that finishes with a question replaces its own running card, and the question shows first.
        q.add(NotchAlert(id: "run:b/r", kind: .question, symbol: "x", title: "b", message: "?", automationID: "b", runID: "r"))
        XCTAssertEqual(q.entries.filter { $0.alert.automationID == "b" }.map(\.alert.id), ["run:b/r"])
        XCTAssertEqual(q.presentation?.id, "run:b/r")
    }

    @MainActor func testAnOpenListThatDropsToOneKeepsItOpen() {
        let one = running("one"), two = running("two")
        let list = NotchQueue.stack([one, two])
        XCTAssertEqual(NotchAlertController.nextMode(previous: list, previousMode: .detail, next: one, replyTarget: nil), .detail)
        XCTAssertEqual(NotchAlertController.nextMode(previous: list, previousMode: .pill, next: one, replyTarget: nil), .pill)
        XCTAssertEqual(NotchAlertController.nextMode(previous: list, previousMode: .detail, next: running("other"), replyTarget: nil), .pill)
    }

    func testRunningCardIsCompact() {
        let g = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 200, notchHeight: 32)
        let single = running("one")
        XCTAssertEqual(g.bodyHeight(.detail, alert: single), NotchGeometry.cardBody)
        XCTAssertEqual(g.width(.detail), NotchGeometry.cardWidth)
    }

    // MARK: Material

    func testMaterialIsLiveOnlyOnScreenAndSolidWithReduceTransparency() {
        XCTAssertEqual(NotchMaterial.choose(live: true, reduceTransparency: false, glassAvailable: true), .glass)
        XCTAssertEqual(NotchMaterial.choose(live: true, reduceTransparency: false, glassAvailable: false), .blur)
        XCTAssertEqual(NotchMaterial.choose(live: false, reduceTransparency: false, glassAvailable: true), .smokeOnly,
                       "an offscreen render never claims glass")
        for live in [true, false] {
            for glass in [true, false] {
                XCTAssertEqual(NotchMaterial.choose(live: live, reduceTransparency: true, glassAvailable: glass), .solid)
            }
        }
        XCTAssertTrue(NotchSmoke.make(.solid, increaseContrast: false).fill(height: 160, band: 32, openness: 1).allSatisfy { $0.opacity == 1 },
                      "Reduce Transparency draws opaque black")
    }

    /// Beside the hardware notch the island is always opaque black, closed or open, so no seam or hole shows there.
    func testTheNotchBandStaysBlackAndOnlyTheBodyIsTranslucent() {
        for material in [NotchMaterial.glass, .blur, .smokeOnly] {
            let smoke = NotchSmoke.make(material, increaseContrast: false)
            for height: CGFloat in [20, 32, 64, 128, 272] {
                for openness: CGFloat in [0, 0.4, 1] {
                    let stops = smoke.fill(height: height, band: 32, openness: openness)
                    XCTAssertEqual(stops.map(\.location), stops.map(\.location).sorted(), "stops run top to bottom")
                    XCTAssertTrue(stops.allSatisfy { (0...1).contains($0.location) })
                    XCTAssertTrue(stops.filter { $0.location <= min(1, 32 / height) }.allSatisfy { $0.opacity == 1 }, "the band is opaque")
                    if openness == 0 { XCTAssertTrue(stops.allSatisfy { $0.opacity == 1 }, "the pill joins the notch in black") }
                }
                XCTAssertTrue(smoke.edge(height: height, band: 32).filter { $0.location <= min(1, 32 / height) }.allSatisfy { $0.opacity == 0 },
                              "no edge light along the notch or the menu bar")
            }
            let open = smoke.fill(height: 128, band: 32, openness: 1)
            XCTAssertLessThan(open.last!.opacity, 1, "the open body lets light through")
            XCTAssertGreaterThanOrEqual(open.last!.opacity, 0.6, "and stays dark enough for white text")
            let plain = smoke.fill(height: 128, band: 0, openness: 1)
            XCTAssertTrue(plain.allSatisfy { $0.opacity < 1 }, "without a notch the whole card is translucent")
            XCTAssertTrue(smoke.fill(height: 128, band: 0, openness: 0).allSatisfy { $0.opacity == 1 })
        }
        // Both switches on: Reduce Transparency picks the opaque surface with no material behind it, and Increase
        // Contrast must not lighten it, or the desktop would show through. Only the edge gets firmer.
        let both = NotchSmoke.make(NotchMaterial.choose(live: true, reduceTransparency: true, glassAvailable: true), increaseContrast: true)
        for height: CGFloat in [20, 60, 128, 272] {
            for band: CGFloat in [0, 32] {
                XCTAssertTrue(both.fill(height: height, band: band, openness: 1).allSatisfy { $0.opacity == 1 },
                              "opaque with Reduce Transparency and Increase Contrast, height \(height), band \(band)")
            }
        }
        XCTAssertGreaterThan(both.edgeBottom, NotchSmoke.make(.solid, increaseContrast: false).edgeBottom)
        XCTAssertGreaterThan(both.edgeWidth, NotchSmoke.make(.solid, increaseContrast: false).edgeWidth)
        for material in [NotchMaterial.glass, .blur, .smokeOnly, .solid] {
            let plain = NotchSmoke.make(material, increaseContrast: false), firm = NotchSmoke.make(material, increaseContrast: true)
            XCTAssertTrue(firm.top >= plain.top && firm.bottom >= plain.bottom, "Increase Contrast never lightens \(material)")
        }
        let contrast = NotchSmoke.make(.glass, increaseContrast: true)
        XCTAssertGreaterThan(contrast.bottom, NotchSmoke.make(.glass, increaseContrast: false).bottom, "Increase Contrast is darker")
        XCTAssertGreaterThan(contrast.edgeBottom, NotchSmoke.make(.glass, increaseContrast: false).edgeBottom, "with a firmer edge")
    }

    // MARK: Native demo

    /// The on-screen demo holds one running, then several, long enough to click; then work that needs the user
    /// takes over the notch, as the real queue decides. Times are fixed, so nothing cycles.
    @MainActor func testNotchDemoTimelineHoldsEachStateAndUsesTheRealQueue() throws {
        let steps = NotchDemo.timeline(start: Date(timeIntervalSince1970: 1_790_000_000))
        let gaps = zip(steps.map(\.at), steps.dropFirst().map(\.at) + [NotchDemo.quitAt]).map { $1 - $0 }
        XCTAssertEqual(steps.first?.at, 0)
        XCTAssertTrue(gaps.allSatisfy { $0 >= 20 }, "each state stays at least 20 s: \(gaps)")
        var q = NotchQueue()
        var shown: [NotchAlert] = []
        for step in steps {
            for alert in step.alerts { q.add(alert) }
            shown.append(try XCTUnwrap(q.presentation))
        }
        XCTAssertEqual(shown[0].kind, .running)
        XCTAssertFalse(shown[0].isStack, "first a single running pill")
        XCTAssertTrue(shown[1].presentation.isRunningStack)
        XCTAssertEqual(shown[1].stackCount, 3)
        XCTAssertEqual(shown[1].presentation.identities.count, 3, "three distinct icons")
        XCTAssertEqual(shown[2].kind, .review, "a review hides running work")
        XCTAssertEqual(shown[3].stack.map(\.kind), [.review, .question], "and a question joins it in one stack")
    }

    // MARK: Editor and window

    func testDraftKeepsTheSavedLookAndChecksAChangedSymbol() {
        var a = automation(staged: false, accent: nil)
        a.symbol = "a.symbol.from.a.newer.macos"
        var d = AutomationDraft(a)
        XCTAssertEqual(d.symbol, a.symbol, "the saved symbol is kept")
        XCTAssertEqual(d.accent, AutomationAccent.fallback(for: a.id), "it opens with the colour it already showed")
        let exists: (String) -> Bool = { _ in false }
        XCTAssertFalse(d.problems(isExecutable: { _ in true }, symbolExists: exists).contains { $0.contains("SF Symbol") },
                       "an unchanged symbol is not refused")
        d.symbol = "not.a.symbol"
        XCTAssertTrue(d.problems(isExecutable: { _ in true }, symbolExists: exists).contains { $0.contains("SF Symbol") })
        d.symbol = a.symbol; d.accent = .graphite
        let built = d.build(isExecutable: { _ in true }, symbolExists: exists)
        XCTAssertEqual(built?.accent, "graphite")
        XCTAssertEqual(built?.symbol, a.symbol)
        XCTAssertEqual(AutomationDraft().accent, .blue)
    }

    func testEveryOfferedSymbolExists() {
        XCTAssertEqual(Set(AutomationSymbols.all).count, AutomationSymbols.all.count)
        for symbol in AutomationSymbols.all { XCTAssertTrue(AutomationSymbols.exists(symbol), symbol) }
        XCTAssertEqual(AutomationSymbols.valid("../../etc"), AutomationSymbol.fallback)
    }

    @MainActor func testDetailsOpenTheExactRun() throws {
        let model = AutomationsViewModel(center: nil, quill: nil, demo: AutomationsDemoData.make())
        let target = try XCTUnwrap(model.allRuns.first)
        let other = try XCTUnwrap(model.automations.first { $0.id != target.automationID })
        model.open(automationID: other.id, runID: target.id)
        XCTAssertNil(model.selectedRunID, "a run ID under another automation is not opened")
        XCTAssertEqual(model.selectedAutomationID, other.id)
        model.open(automationID: target.automationID, runID: target.id)
        XCTAssertEqual(model.selectedRunID, target.id)
    }
}
