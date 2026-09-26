import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class AutomationReviewTests: XCTestCase {
    private func automation() -> Automation {
        Automation(id: "review-task", name: "Review", kind: .agent(AgentTask(prompt: "Report", workingDirectory: "/tmp")),
                   schedule: Schedule(rule: .manual))
    }

    func testEditingPreservesNoneEffortAndExactArguments() throws {
        var a = automation()
        a.kind = .agent(AgentTask(prompt: "Report", effort: .none, workingDirectory: "/tmp"))
        XCTAssertEqual(AutomationDraft(a).agentTask.effort, .none)
        let args = ["", " spaced ", "two\nlines", "last"]
        a.kind = .script(ScriptTask(executable: "/bin/echo", arguments: args, workingDirectory: "/tmp"))
        var draft = AutomationDraft(a)
        draft.name = "Changed title"
        XCTAssertEqual(draft.scriptTask.arguments, args)
        draft.argumentsText = "  keep spaces  \nnext"
        XCTAssertEqual(draft.arguments, ["  keep spaces  ", "next"])
    }

    func testToolbarUsesOnlyVisibleSectionSelection() {
        let model = AutomationsViewModel(center: nil, quill: nil, demo: AutomationsDemoData.make())
        model.selectedAutomationID = model.automations.first?.id
        XCTAssertNotNil(model.runnableSelection)
        model.section = .clients
        XCTAssertNil(model.runnableSelection)
        model.section = .history
        model.selectedRunID = model.allRuns.first?.id
        XCTAssertEqual(model.runnableSelection, model.selectedRun?.automationID)
        model.search = "no matching run"
        XCTAssertNil(model.runnableSelection)
    }

    func testRunContentVersionChangesOnCompletion() {
        var run = RunRecord(id: RunID.make(), automation: automation(), trigger: .manual, occurrence: nil)
        run.state = .running
        let before = RunContentVersion(run)
        run.state = .succeeded; run.outputFile = "output.md"; run.finished = Date()
        XCTAssertNotEqual(before, RunContentVersion(run))
    }

    func testAlertReceiptDoesNotOverwriteNewRunnerState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)
        var run = RunRecord(id: RunID.make(), automation: automation(), trigger: .manual, occurrence: nil)
        run.state = .needsInput; run.started = Date()
        let shown = run
        run.state = .running
        try store.saveRun(run)
        try AutomationAlertReceipt.save(shown, store: store)
        XCTAssertEqual(store.run(automationID: run.automationID, runID: run.id)?.state, .running)
        XCTAssertTrue(AutomationAlertReceipt.wasDelivered(shown, store: store))
        XCTAssertFalse(AutomationAlertReceipt.wasDelivered(run, store: store))
        var later = shown; later.started = shown.started?.addingTimeInterval(10)
        XCTAssertFalse(AutomationAlertReceipt.wasDelivered(later, store: store))
    }

    func testCenterErrorsReachWindow() {
        let store = AutomationStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let center = AutomationCenter(isolatedStore: store)
        let model = AutomationsViewModel(center: center, quill: nil)
        center.message = "Could not save"
        XCTAssertEqual(model.banner, "Could not save")
    }

    func testFailedRequestDoesNotClaimAnswerWasSent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let center = AutomationCenter(store: AutomationStore(root: file))
        let run = RunRecord(id: RunID.make(), automation: automation(), trigger: .manual, occurrence: nil)
        XCTAssertFalse(center.answer(run, "Yes"))
        XCTAssertNotNil(center.message)
    }
    func testNewDraftUsesSettingsWithoutGivingProposalTemplatesWriteAccess() {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.automationRunner = .claude
        preferences.automationClaudeModel = "sonnet"
        preferences.automationEffort = .none
        preferences.automationAccess = .workspaceWrite
        preferences.automationTimeoutMinutes = 30
        var draft = AutomationDraft()
        draft.applyDefaults(preferences)
        XCTAssertEqual(draft.runner, .claude)
        XCTAssertEqual(draft.model, "sonnet")
        XCTAssertEqual(draft.effort, .none)
        XCTAssertEqual(draft.access, .workspaceWrite)
        XCTAssertEqual(draft.policy.timeout, 1800)
        var proposal = AutomationTemplate.desktopTidy.draft()
        proposal.applyDefaults(preferences)
        XCTAssertEqual(proposal.access, .readOnly)
    }

    func testDeleteRefusesActiveRunWithoutTouchingItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)
        let center = AutomationCenter(isolatedStore: store)
        let a = automation()
        center.save(a)
        var run = RunRecord(id: RunID.make(), automation: a, trigger: .manual, occurrence: nil)
        run.state = .running
        try store.saveRun(run)
        center.delete(a.id)
        XCTAssertNotNil(store.automation(id: a.id))
        XCTAssertNotNil(store.run(automationID: a.id, runID: run.id))
        XCTAssertNotNil(center.message)
    }

    nonisolated func testToolProbeRejectsFailedVersionCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fake-tool")
        try Data("#!/bin/sh\nprintf 'not a version\\n'\nexit 1\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertNil(ToolProbe.version(file.path))
    }

    func testClientPathChangeDoesNotKeepAnotherFilesMetrics() throws {
        var previous = try XCTUnwrap(AutomationsDemoData.make().clients.first)
        previous.config.metricsPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        var changed = previous.config
        changed.metricsPath += "-changed"
        let entry = AutomationCenter.read(changed, previous: previous)
        XCTAssertNil(entry.snapshot)
        XCTAssertNotNil(entry.readError)
        let stale = AutomationCenter.read(previous.config, previous: previous)
        XCTAssertNotNil(stale.snapshot)
        XCTAssertNotNil(stale.readError)
    }

}
