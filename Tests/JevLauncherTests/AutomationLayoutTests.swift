import XCTest
import SwiftUI
import LauncherCore
@testable import JevLauncher

/// The Automations window at small sizes, and what its lists show: order, folded failures, short schedules.
@MainActor
final class AutomationLayoutTests: XCTestCase {
    func testColumnsNeverSqueezeTheDetailBelowItsMinimum() {
        typealias L = AutomationsLayout
        XCTAssertEqual(L.columns(width: 1020), .split(list: L.listMaximum), "a normal window caps the list")
        XCTAssertEqual(L.columns(width: 760), .split(list: 289))
        XCTAssertEqual(L.columns(width: L.windowMinimum.width), .split(list: L.listMinimum))
        XCTAssertEqual(L.columns(width: 620), .stacked)
        XCTAssertEqual(L.columns(width: 300), .stacked)
        for width in stride(from: CGFloat(621), through: 1600, by: 7) {
            guard case .split(let list) = L.columns(width: width) else { return XCTFail("stacked at \(width)") }
            XCTAssertGreaterThanOrEqual(list, L.listMinimum)
            XCTAssertGreaterThanOrEqual(width - list - 1, L.detailMinimum, "detail at \(width)")
        }
        XCTAssertEqual(AutomationsWindow.minimumSize, L.windowMinimum)
    }

    func testSidebarHidesOnlyWhenTheWidthCrossesTheLimit() {
        let model = AutomationsViewModel(center: nil, quill: nil)
        model.resetColumns(windowWidth: 1240)
        XCTAssertEqual(model.columnVisibility, .all)
        model.windowWidthChanged(AutomationsLayout.sidebarFitsWidth - 1)
        XCTAssertEqual(model.columnVisibility, .detailOnly, "narrow hides the sidebar")
        model.columnVisibility = .all
        model.windowWidthChanged(AutomationsLayout.sidebarFitsWidth - 20)
        XCTAssertEqual(model.columnVisibility, .all, "the toolbar choice stays while the width stays narrow")
        model.windowWidthChanged(1100)
        model.columnVisibility = .detailOnly
        model.windowWidthChanged(1200)
        XCTAssertEqual(model.columnVisibility, .detailOnly, "a hidden sidebar stays hidden while wide")
        model.resetColumns(windowWidth: 1200)
        XCTAssertEqual(model.columnVisibility, .all, "each open shows it again when it fits")
        model.resetColumns(windowWidth: 700)
        XCTAssertEqual(model.columnVisibility, .detailOnly)
    }

    func testListsShowNewestFirstAndFoldRepeatedFailures() throws {
        let demo = AutomationsDemoData.make()
        let model = AutomationsViewModel(center: nil, quill: nil, demo: demo)
        let backup = AutomationsDemoData.backupID
        let runs = model.runs(for: backup)
        XCTAssertEqual(runs.map(\.queued), runs.map(\.queued).sorted(by: >))

        let streaks = model.streaks(for: backup)
        XCTAssertEqual(streaks.map(\.count), [6, 1, 1, 1], "six identical failures, then three successes")
        XCTAssertEqual(streaks.first?.runs.map(\.id), Array(runs.prefix(6)).map(\.id))
        XCTAssertEqual(model.explanation(runs[0])?.kind, .needsReview)
        XCTAssertEqual(model.runs(in: .failed).count, 8, "every failure is still listed for the week")
        XCTAssertEqual(model.count(.failed), 3, "the badge counts the folded entries")

        let automation = try XCTUnwrap(model.automation(backup))
        XCTAssertEqual(ScheduleText.summary(automation.schedule), "Hourly · On the hour")
        XCTAssertNil(ScheduleText.allTimes(automation.schedule))
    }

    func testRunNowRunWithRandomIDSortsByTime() {
        let a = Automation(id: "sort-a", name: "Sort", kind: .script(ScriptTask(executable: "/bin/true", workingDirectory: "/")), schedule: Schedule(rule: .manual))
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let manual = RunRecord(id: "f4b39360-927d-4bf0-900a-cbd99db68e08", automation: a, trigger: .manual, occurrence: nil, queued: base)
        let scheduled = RunRecord(id: RunID.occurrence(automationID: a.id, date: base.addingTimeInterval(3600)), automation: a,
                                  trigger: .schedule, occurrence: base.addingTimeInterval(3600), queued: base.addingTimeInterval(3600))
        XCTAssertEqual(AutomationsViewModel.newestFirst([manual, scheduled]).map(\.id), [scheduled.id, manual.id])
    }
}
