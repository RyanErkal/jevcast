import XCTest
import LauncherCore
@testable import JevLauncher

final class AutomationDraftTests: XCTestCase {
    private func schedule(_ text: String) -> Schedule { Schedule(rule: .rrule(text), timeZone: "Europe/London", anchor: Date(timeIntervalSince1970: 0)) }

    func testPresetsBuildRules() {
        var d = ScheduleDraft()
        d.preset = .everyHours; d.intervalHours = 4
        XCTAssertEqual(d.presetRuleText, "FREQ=HOURLY;INTERVAL=4")
        d.preset = .daily; d.hour = 8; d.minute = 30
        XCTAssertEqual(d.presetRuleText, "FREQ=DAILY;BYHOUR=8;BYMINUTE=30")
        d.preset = .weekdays; d.hour = 4
        XCTAssertEqual(d.presetRuleText, "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=4;BYMINUTE=30")
        d.preset = .weekly; d.weekdays = [1, 4]; d.hour = 18; d.minute = 0
        XCTAssertEqual(d.presetRuleText, "FREQ=WEEKLY;BYDAY=WE,SU;BYHOUR=18;BYMINUTE=0")
        guard case .success(.rrule(let text)) = d.rule() else { return XCTFail("Weekly should be valid") }
        XCTAssertEqual(text, "FREQ=WEEKLY;BYDAY=WE,SU;BYHOUR=18;BYMINUTE=0")
    }

    func testRulesParseBackIntoPresets() {
        XCTAssertEqual(ScheduleDraft(schedule("FREQ=HOURLY;INTERVAL=6")).preset, .everyHours)
        XCTAssertEqual(ScheduleDraft(schedule("FREQ=HOURLY;INTERVAL=6")).intervalHours, 6)
        let daily = ScheduleDraft(schedule("FREQ=DAILY;BYHOUR=8;BYMINUTE=30"))
        XCTAssertEqual(daily.preset, .daily); XCTAssertEqual(daily.hour, 8); XCTAssertEqual(daily.minute, 30)
        XCTAssertEqual(ScheduleDraft(schedule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=4;BYMINUTE=30")).preset, .weekdays)
        let weekly = ScheduleDraft(schedule("FREQ=WEEKLY;BYDAY=SU;BYHOUR=18;BYMINUTE=0"))
        XCTAssertEqual(weekly.preset, .weekly); XCTAssertEqual(weekly.weekdays, [1])
        XCTAssertEqual(ScheduleDraft(schedule("FREQ=DAILY;INTERVAL=2;BYHOUR=8;BYMINUTE=0")).preset, .custom)
        XCTAssertEqual(ScheduleDraft(schedule("FREQ=DAILY;BYHOUR=8,20;BYMINUTE=0")).preset, .custom)
        XCTAssertEqual(ScheduleDraft(schedule("NONSENSE")).preset, .custom)
        XCTAssertEqual(ScheduleDraft(Schedule(rule: .manual)).preset, .manual)
        // Round trip keeps the time zone and anchor.
        let round = ScheduleDraft(schedule("FREQ=HOURLY;INTERVAL=4")).schedule()
        XCTAssertEqual(round, schedule("FREQ=HOURLY;INTERVAL=4"))
    }

    func testScheduleProblems() {
        var d = ScheduleDraft()
        d.preset = .custom; d.customText = "FREQ=MONTHLY"
        guard case .failure(let p) = d.rule() else { return XCTFail() }
        XCTAssertTrue(p.message.contains("MONTHLY"))
        d.preset = .weekly; d.weekdays = []
        XCTAssertEqual(d.rule(), .failure(.init("Pick at least one day.")))
        d.preset = .once; d.onceDate = Date(timeIntervalSinceNow: -60)
        XCTAssertEqual(d.rule(), .failure(.init("Pick a time in the future.")))
        d.preset = .daily; d.timeZone = "Not/AZone"
        XCTAssertEqual(d.rule(), .failure(.init("Choose a valid time zone.")))
    }

    func testValidationExplainsWhySaveIsOff() {
        var d = AutomationDraft()
        let ok: (String) -> Bool = { _ in true }
        XCTAssertTrue(d.problems(isExecutable: ok).contains("Add a name."))
        XCTAssertTrue(d.problems(isExecutable: ok).contains("Write a prompt."))
        XCTAssertTrue(d.problems(isExecutable: ok).contains("Choose a working folder."))
        d.name = "Tidy"; d.prompt = "Tidy"; d.agentFolder = "~/Desktop"; d.output = .proposal
        XCTAssertEqual(d.problems(isExecutable: ok), ["“Changes to approve” needs at least one allowed folder."])
        d.allowedRoots = ["~/Desktop"]
        XCTAssertEqual(d.problems(isExecutable: ok), [])

        d.kind = .script; d.program = "/opt/homebrew/bin/bun"; d.scriptFolder = "~/Dev/docs"
        XCTAssertEqual(d.problems(isExecutable: { _ in false }), ["The program is not an executable file."])
        d.program = "bun"
        XCTAssertTrue(d.problems(isExecutable: ok).first?.contains("full path") == true)
        d.program = "/bin/echo"; d.environment = [.init(key: "BAD NAME", value: "x")]
        XCTAssertEqual(d.problems(isExecutable: ok), ["Environment names use letters, digits, and _ only."])
    }

    func testBuildSavesNewAutomationsPausedAndKeepsEditsIdentity() throws {
        var d = AutomationTemplate.desktopTidy.draft(home: "/Users/x")
        let built = try XCTUnwrap(d.build(isExecutable: { _ in true }))
        XCTAssertFalse(built.enabled, "New automations are saved paused.")
        XCTAssertTrue(AutomationID.isValid(built.id))
        guard case .agent(let agent) = built.kind else { return XCTFail() }
        XCTAssertEqual(agent.output, .proposal)
        XCTAssertEqual(agent.allowedRoots, [Paths.home + "/Desktop"])
        XCTAssertEqual(built.schedule.rule, .rrule("FREQ=WEEKLY;BYDAY=SU;BYHOUR=18;BYMINUTE=0"))

        var saved = built; saved.enabled = true; saved.revision = 3
        d = AutomationDraft(saved)
        d.name = "Desk"
        let edited = try XCTUnwrap(d.build(isExecutable: { _ in true }))
        XCTAssertEqual(edited.id, saved.id); XCTAssertEqual(edited.revision, 3); XCTAssertTrue(edited.enabled)
        XCTAssertEqual(edited.name, "Desk")
    }

    func testMetricsTemplateIsScriptWithDiagnosis() throws {
        let d = AutomationTemplate.metricsRefresh.draft(bunPath: "/opt/homebrew/bin/bun")
        let built = try XCTUnwrap(d.build(isExecutable: { _ in true }))
        guard case .scriptWithDiagnosis(let script, let agent) = built.kind else { return XCTFail() }
        XCTAssertEqual(script.arguments, ["scripts/utils/redesign-daily-metrics.ts", "--client", "stein-firm"])
        XCTAssertEqual(agent.access, .readOnly)
        XCTAssertEqual(built.policy.sharedLock, "docs-metrics")
        XCTAssertEqual(built.schedule.rule, .rrule("FREQ=HOURLY;INTERVAL=4"))
    }
}
