import XCTest
import LauncherCore
@testable import JevLauncher

/// Jev stand-in that answers each call from its candidates, and records every call.
final class ScriptedJev: JevChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[JevCandidate]] = []
    var calls: [[JevCandidate]] { lock.withLock { _calls } }
    let answer: @Sendable ([JevCandidate]) -> String?
    init(answer: @escaping @Sendable ([JevCandidate]) -> String?) { self.answer = answer }
    func choose(query: String, candidates: [JevCandidate], apiKey: String) async throws -> String? {
        lock.withLock { _calls.append(candidates) }
        return answer(candidates)
    }
}

final class JevLayerTests: XCTestCase {
    func testPlan() {
        XCTAssertEqual(JevLayerPlan.decide(pick: "app:x", pickKind: .openApp, kind: .openApp), .accept("app:x"))
        XCTAssertEqual(JevLayerPlan.decide(pick: "app:x", pickKind: .openApp, kind: .window), .narrow(.window))
        XCTAssertEqual(JevLayerPlan.decide(pick: nil, pickKind: nil, kind: .organizer), .noMatch, "The kind alone never picks.")
        XCTAssertEqual(JevLayerPlan.decide(pick: "app:x", pickKind: .openApp, kind: nil), .accept("app:x"))
        XCTAssertEqual(JevLayerPlan.decide(pick: nil, pickKind: nil, kind: nil), .noMatch)
        XCTAssertEqual(JevKind.of("window:left-half"), .window)
        XCTAssertEqual(JevKind.of("app:/A.app", isSettingsPane: true), .settingsPane)
        XCTAssertEqual(JevKind.of(QuillStorageKeys.selectionRowPrefix + "custom"), .quill)
        XCTAssertEqual(JevKind.of(QuillStorageKeys.selectionRowPrefix + "shorter"), .quill)
        XCTAssertEqual(JevKind.of("route:calendar"), .organizer)
    }

    @MainActor private func makeModel(_ jev: ScriptedJev, layered: Bool) -> (LauncherModel, () -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = true; preferences.jevLayered = layered; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), jev: jev,
                                  keys: JevKeyCache(key: "test-key"), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        return (model, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor func testDisagreementNarrowsToTheKind() async throws {
        let rightHalf = WindowAction.rightHalf.title
        let jev = ScriptedJev { candidates in
            // The kind step says "window". The single list wrongly picks the first command.
            if let kind = candidates.first(where: { $0.title == JevKind.window.title }) { return kind.id }
            if candidates.contains(where: { $0.title == JevKind.openApp.title || $0.title == JevKind.command.title }) { return nil }
            // The full list picks a command: the wrong kind, so Jev chooses again among window actions.
            if candidates.allSatisfy({ WindowAction.allCases.map(\.title).contains($0.title) }) {
                return candidates.first { $0.title == rightHalf }?.id
            }
            return candidates.first { candidate in SystemCommands.all.contains { $0.title == candidate.title } }?.id
        }
        let (model, cleanup) = makeModel(jev, layered: true)
        defer { cleanup() }
        model.begin(); defer { model.end() }
        model.updateQuery("shove it over to the other side please", typed: true)
        try await until(timeout: 3) { model.aiStatus == "Jev matched" || model.aiStatus == "No clear AI match" }
        XCTAssertEqual(model.selected?.id, "window:right-half")
        XCTAssertGreaterThanOrEqual(jev.calls.count, 3, "Single list and kind together, then the window list.")
        let narrowed = jev.calls.first { $0.allSatisfy { WindowAction.allCases.map(\.title).contains($0.title) } }
        XCTAssertEqual(narrowed?.count, WindowAction.allCases.count, "The second step sees every window action.")
    }

    @MainActor func testAgreementNeedsNoThirdCall() async throws {
        let jev = ScriptedJev { candidates in
            if let kind = candidates.first(where: { $0.title == JevKind.window.title }) { return kind.id }
            return candidates.first { $0.title == WindowAction.maximize.title }?.id
        }
        let (model, cleanup) = makeModel(jev, layered: true)
        defer { cleanup() }
        model.begin(); defer { model.end() }
        model.updateQuery("make it huge please", typed: true)
        try await until(timeout: 3) { model.aiStatus == "Jev matched" }
        XCTAssertEqual(model.selected?.id, "window:maximize")
        XCTAssertEqual(jev.calls.count, 2)
    }
}

/// Jev stand-in that sees the query, so it can tell the source question from the target question.
private final class ClockJev: JevChoosing, @unchecked Sendable {
    func choose(query: String, candidates: [JevCandidate], apiKey: String) async throws -> String? {
        if query.hasPrefix("The place the time is in") { return candidates.first { $0.title == "New York" }?.id }
        if query.hasPrefix("The place to give the time in") { return candidates.first { $0.title == "Ireland" }?.id }
        return candidates.first { $0.title == "Convert a time between places" }?.id
    }
}

final class ClockJevTests: XCTestCase {
    @MainActor func testJevChoosesPlacesAndCodeConverts() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = true; preferences.jevLayered = false; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), jev: ClockJev(),
                                  keys: JevKeyCache(key: "test-key"), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        model.begin(); defer { model.end() }
        model.updateQuery("what is 6pm for my mate in cork if im in georgia", typed: true)
        try await until(timeout: 3) { model.aiStatus == "Jev matched" || model.aiStatus == "No clear AI match" }
        XCTAssertEqual(model.selected?.id, "clock")
        XCTAssertTrue(model.selected?.detail.contains("6:00 PM") ?? false)
        XCTAssertTrue(model.selected?.detail.contains("New York → Ireland") ?? false)
    }
}
