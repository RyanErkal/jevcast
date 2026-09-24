import AppKit
import SwiftUI
import XCTest
@testable import JevLauncher

final class LauncherPagesTests: XCTestCase {
    @MainActor func testViewKeepsTypedSearchAndRestoresItOnBack() {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false),
                                  keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        model.makePage = { [unowned model] id in LauncherPages.make(id, model: model, links: .init(), snapshot: true) }
        model.begin(); defer { model.end() }
        model.updateQuery("clip", typed: true)
        XCTAssertEqual(model.results.first?.id, "view:clipboard")

        model.showView(.clipboard)
        XCTAssertEqual(model.mode, .view(.clipboard))
        XCTAssertEqual(model.query, "")
        model.filterView("abc")
        XCTAssertEqual(model.query, "abc")

        model.closeView()
        XCTAssertEqual(model.mode, .search)
        XCTAssertEqual(model.query, "clip")
    }

    @MainActor private func makeModel(_ page: SpyPage) -> (LauncherModel, () -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false),
                                  keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        model.makePage = { _ in page }
        model.begin()
        return (model, { model.end(); defaults.removePersistentDomain(forName: suite) })
    }

    private func key(_ code: UInt16, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: repeating, keyCode: code)!
    }

    @MainActor func testHeldDeleteNeverDeletesButOnePressDoes() {
        let page = SpyPage()
        let (model, done) = makeModel(page); defer { done() }
        model.showView(.mail)
        XCTAssertTrue(model.handleViewKey(key(51, repeating: true)))
        XCTAssertEqual(page.keys, [])
        XCTAssertTrue(model.handleViewKey(key(51)))
        XCTAssertEqual(page.keys, [.delete])
        model.filterView("abc")
        XCTAssertFalse(model.handleViewKey(key(51)), "⌫ edits a filter with text.")
        XCTAssertEqual(page.keys, [.delete])
    }

    @MainActor func testClosingAllViewsReturnsToSearchWithoutReopening() {
        let page = SpyPage()
        let (model, done) = makeModel(page); defer { done() }
        model.updateQuery("hello", typed: true)
        model.showView(.mail)
        XCTAssertFalse(model.acceptsSpeech, "Opening a view stops voice.")
        XCTAssertTrue(model.handleViewKey(key(53)), "Escape at the list goes back.")
        XCTAssertEqual(model.mode, .search)
        XCTAssertEqual(model.query, "hello")
        model.showView(.mail)
        model.closeAllViews()
        XCTAssertEqual(model.mode, .search)
        XCTAssertEqual(model.query, "hello")
        XCTAssertEqual(page.opens, 2)
    }

    @MainActor func testSearchRowsIgnoreTheViewFilterAndComeBackAfter() {
        let page = SpyPage()
        let (model, done) = makeModel(page); defer { done() }
        model.updateQuery("clip", typed: true)
        let before = model.results.map(\.id)
        model.showView(.mail)
        model.filterView("zzqx")
        model.rebuild()
        XCTAssertEqual(model.results.map(\.id), before, "The view's filter never rebuilds the search rows.")
        model.closeView()
        XCTAssertEqual(model.query, "clip")
        XCTAssertEqual(model.results.map(\.id), before)
    }

    @MainActor func testRowsFromAnOldListCannotRunWhileItReloads() async throws {
        let page = SpyPage()
        let (model, done) = makeModel(page); defer { done() }
        let source = CountingSource()
        let view = SourcePage(.cleanup, source: source, model: model, hasDetail: false, emptyText: "")
        view.reload()
        try await waitFor { !view.rows.isEmpty }
        source.hold = true
        XCTAssertTrue(view.handle(.open(shift: false)))
        try await waitFor { source.runs == 1 }
        view.filter("")
        XCTAssertTrue(view.handle(.open(shift: false)))
        XCTAssertEqual(source.runs, 1, "A stale row does not run again after the filter changes.")
        source.hold = false
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testEveryViewSymbolExists() {
        for view in ViewID.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: view.symbol, accessibilityDescription: nil), "\(view) uses missing symbol \(view.symbol)")
        }
    }
    @MainActor func testCalendarStartsOnMonthAndArrowsSwitchViews() {
        let page = SpyPage()
        let (model, done) = makeModel(page); defer { done() }
        let list = SourcePage(.calendar, source: nil, model: model, hasDetail: true, emptyText: "")
        let calendar = CalendarPage(list: list, readsEvents: false)
        calendar.opened(); defer { calendar.closed(handingOff: false) }
        XCTAssertEqual(calendar.mode, CalendarPage.Mode.month)
        XCTAssertEqual(calendar.days.count % 7, 0, "The month shows whole weeks.")
        XCTAssertTrue(calendar.days.count >= 28)
        XCTAssertTrue(calendar.handle(.right)); XCTAssertEqual(calendar.mode, CalendarPage.Mode.week)
        XCTAssertEqual(calendar.days.count, 7)
        XCTAssertTrue(calendar.handle(.right)); XCTAssertEqual(calendar.mode, CalendarPage.Mode.list)
        XCTAssertTrue(calendar.handle(.right)); XCTAssertEqual(calendar.mode, CalendarPage.Mode.month)
        XCTAssertTrue(calendar.handle(.left)); XCTAssertEqual(calendar.mode, CalendarPage.Mode.list)
        calendar.setMode(.month)
        let start = calendar.days[10]
        XCTAssertTrue(calendar.handle(.down))
        XCTAssertNotEqual(calendar.days[10], start, "↓ moves to the next month.")
    }
}

@MainActor private final class SpyPage: LauncherPage {
    let id = ViewID.mail
    var keys: [PageKey] = []
    var opens = 0
    func handle(_ key: PageKey) -> Bool { keys.append(key); return true }
    func filter(_ text: String) {}
    func back() -> Bool { false }
    func opened() { opens += 1 }
    func content() -> AnyView { AnyView(EmptyView()) }
}

@MainActor private final class CountingSource: ThingSource {
    let section = "Test"
    var runs = 0
    /// Holds the reload after a verb, so the list stays stale.
    var hold = false
    func load(_ filter: String) async throws -> [LauncherResult] {
        while hold { try await Task.sleep(nanoseconds: 10_000_000) }
        let verb = Verb(title: "Do", after: .stay) { [weak self] in self?.runs += 1; return nil }
        return [LauncherResult(id: "row", title: "Row", detail: "", symbol: "circle", action: .thing(Thing(verbs: [verb])), score: 1)]
    }
}
