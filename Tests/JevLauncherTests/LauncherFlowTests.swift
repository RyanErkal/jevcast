import XCTest
import LauncherCore
@testable import JevLauncher

final class LauncherFlowTests: XCTestCase {
    @MainActor private func withModel(_ body: (LauncherModel) -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false
        preferences.jevEnabled = false
        preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false),
                                  keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        model.begin()
        defer { model.end() }
        body(model)
    }
    @MainActor private func makeModel(jev: JevChoosing, files: FileSearching? = nil, board: FakePasteboard? = nil) -> (LauncherModel, Preferences, UserDefaults, String) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = true; preferences.fileFolders = []
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), files: files ?? InstantFileSearch(),
                                  jev: jev, keys: JevKeyCache(key: "test-key"), clipboard: ClipboardHistory(pasteboard: board ?? FakePasteboard()))
        return (model, preferences, defaults, suite)
    }
    @MainActor func testJevReplyPromotesChosenWindowAction() async throws {
        let jev = HeldJev()
        let (model, _, defaults, suite) = makeModel(jev: jev)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("make it huge please", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        let id = try XCTUnwrap(jev.candidates.first { $0.title == WindowAction.maximize.title }?.id)
        XCTAssertFalse(id.contains("window:"), "Candidate IDs are opaque.")
        jev.reply(id)
        try await waitUntil { model.selected?.id == "window:maximize" }
        XCTAssertEqual(model.results.first?.id, "window:maximize")
        XCTAssertEqual(model.aiStatus, "Jev matched")
    }
    @MainActor func testStaleJevReplyCannotPromote() async throws {
        let jev = HeldJev()
        let (model, _, defaults, suite) = makeModel(jev: jev)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("make it huge please", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        let id = try XCTUnwrap(jev.candidates.first { $0.title == WindowAction.maximize.title }?.id)
        jev.onChoose = nil
        model.updateQuery("left half", typed: true)
        jev.reply(id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.selected?.id, "window:left-half")
        XCTAssertNotEqual(model.aiStatus, "Jev matched")
    }
    @MainActor func testJevErrorsMapToStatus() async throws {
        let jev = HeldJev()
        let (model, _, defaults, suite) = makeModel(jev: jev)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("make it huge please", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        jev.fail(JevServiceError.requestFailed(statusCode: 429))
        try await waitUntil { model.aiStatus == "Jev rate limited" }
    }
    @MainActor func testJevCandidatesCarryNoPaths() async throws {
        let jev = HeldJev()
        let files = InstantFileSearch()
        files.entries = [FileEntry(path: "/Users/someone/Private/huge-plan.txt", name: "huge-plan.txt")]
        let (model, _, defaults, suite) = makeModel(jev: jev, files: files)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("make it huge please", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        XCTAssertTrue(jev.candidates.contains { $0.title == "huge-plan.txt" })
        XCTAssertFalse(jev.candidates.contains { ($0.id + $0.title + $0.detail).contains("/") })
        jev.reply(nil)
    }
    @MainActor func testFileSubtitleShowsFolderButKeepsFullPath() async throws {
        let files = InstantFileSearch()
        let path = NSHomeDirectory() + "/Downloads/invoice.pdf"
        files.entries = [FileEntry(path: path, name: "invoice.pdf")]
        let (model, preferences, defaults, suite) = makeModel(jev: HeldJev(), files: files)
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.jevEnabled = false
        model.begin(); defer { model.end() }
        model.updateQuery("find file invoice", typed: true)
        try await waitUntil { model.results.contains { $0.id == "file:" + path } }
        let row = try XCTUnwrap(model.results.first { $0.id == "file:" + path })
        XCTAssertEqual(row.detail, "~/Downloads")
        XCTAssertEqual(row.path, path)
    }
    @MainActor func testShortMixedQueriesSkipSpotlight() async throws {
        let files = InstantFileSearch()
        let (model, preferences, defaults, suite) = makeModel(jev: HeldJev(), files: files)
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.jevEnabled = false
        model.begin(); defer { model.end() }
        model.updateQuery("ab", typed: true)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(files.searches, 0)
        model.updateQuery("abc", typed: true)
        try await waitUntil { files.searches == 1 }
    }
    @MainActor func testQuicklinkRows() {
        withModel { model in
            model.updateQuery("gh swift ui", typed: true)
            XCTAssertEqual(model.selected?.id, "quicklink:gh")
            XCTAssertEqual(model.selected?.title, "Search GitHub for swift ui")
            model.updateQuery("gh", typed: true)
            XCTAssertEqual(model.selected?.id, "quicklink:gh")
            XCTAssertEqual(model.selected?.title, "Search GitHub")
        }
    }
    @MainActor func testClipboardModeListsAndFiltersEntries() {
        let board = FakePasteboard()
        let (model, _, defaults, suite) = makeModel(jev: HeldJev(), board: board)
        defer { defaults.removePersistentDomain(forName: suite) }
        board.copy("first note"); model.clipboard.poll()
        board.copy("second invoice"); model.clipboard.poll()
        model.begin(); defer { model.end() }
        model.updateQuery("clip", typed: true)
        XCTAssertEqual(model.results.map(\.title), ["second invoice", "first note"])
        model.updateQuery("clip note", typed: true)
        XCTAssertEqual(model.results.map(\.title), ["first note"])
        XCTAssertTrue(model.isClipboardSearch)
    }
    @MainActor func testUseBoostReordersCloseMatchesButNotExactOnes() {
        withModel { model in
            model.updateQuery("third", typed: true)
            let ids = model.results.prefix(3).map(\.id)
            let last = try? XCTUnwrap(ids.last)
            for _ in 0..<30 { model.preferences.record(last!, query: "third") }
            model.rebuild()
            XCTAssertEqual(model.selected?.id, last)
            model.updateQuery("left half", typed: true)
            for _ in 0..<30 { model.preferences.record("window:left-two-thirds", query: "left half") }
            model.rebuild()
            XCTAssertEqual(model.selected?.id, "window:left-half")
        }
    }
    @MainActor func testCalculatorAndWebAreNotRemembered() {
        withModel { model in
            model.updateQuery("2+2", typed: true)
            model.execute()
            XCTAssertTrue(model.preferences.frecency.records.isEmpty)
            XCTAssertTrue(model.preferences.recentIDs.isEmpty)
        }
    }
    @MainActor func testMessageNoticeWinsAndVoiceErrorLeavesFooter() {
        withModel { model in
            model.message = "Boom"
            XCTAssertEqual(model.notice?.tone, .warning)
            XCTAssertEqual(model.notice?.text, "Boom")
            model.message = nil
            XCTAssertNotEqual(model.notice?.tone, .warning)
        }
    }
    @MainActor func testSpokenUpdateRanksCurrentActionAndTypingReplacesIt() {
        withModel { model in
            model.updateQuery("left half", typed: false)
            XCTAssertEqual(model.selected?.id, "window:left-half")
            model.updateQuery("right third", typed: true)
            XCTAssertEqual(model.selected?.id, "window:right-third")
            XCTAssertFalse(model.speech.isListening)
        }
    }
    @MainActor func testLateTranscriptCannotChangeClosedSession() {
        withModel { model in
            model.updateQuery("left half", typed: false)
            model.end()
            model.speech.onTranscript?("right half")
            XCTAssertEqual(model.query, "left half")
        }
    }
    @MainActor func testManualSelectionSurvivesBackgroundRebuild() {
        withModel { model in
            model.updateQuery("half", typed: true)
            model.moveSelection(1)
            let selected = model.selectedID
            model.rebuild()
            XCTAssertEqual(model.selectedID, selected)
            model.updateQuery("right third", typed: true)
            XCTAssertEqual(model.selected?.id, "window:right-third")
        }
    }
    @MainActor func testDuplicateTranscriptPreservesSelection() {
        withModel { model in
            model.updateQuery("half", typed: false)
            model.moveSelection(1)
            let selected = model.selectedID
            model.speech.onTranscript?("half")
            XCTAssertEqual(model.selectedID, selected)
        }
    }
    @MainActor func testTypingWinsOverLateSpeech() {
        withModel { model in
            model.updateQuery("left half", typed: false)
            model.updateQuery("right third", typed: true)
            model.speech.onTranscript?("left half again")
            XCTAssertEqual(model.query, "right third")
        }
    }
    @MainActor func testExplicitFileSearchCannotExecuteOldWindowOrWebResult() {
        withModel { model in
            model.updateQuery("left half", typed: true)
            XCTAssertNotNil(model.selected)
            model.updateQuery("kind:pdf in:downloads", typed: true)
            XCTAssertTrue(model.isFileSearch)
            XCTAssertNil(model.selected)
            XCTAssertTrue(model.results.isEmpty)
        }
    }
    @MainActor func testInvalidFileFilterStaysInFileMode() {
        withModel { model in
            model.updateQuery("kind:unknown invoices", typed: true)
            XCTAssertTrue(model.isFileSearch)
            XCTAssertFalse(model.results.contains { $0.id == "web" })
            XCTAssertFalse(model.fileStatus.isEmpty)
        }
    }
    @MainActor func testOldFilesRemainVisibleButCannotExecuteWhileSearchUpdates() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false
        let files = HeldFileSearch()
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), files: files)
        model.begin()
        defer { model.end() }
        model.updateQuery("find file alpha", typed: true)
        let firstSearch = expectation(description: "first file request")
        files.onSearch = { firstSearch.fulfill() }
        await fulfillment(of: [firstSearch], timeout: 2)
        let oldCompletion = try XCTUnwrap(files.completion)
        oldCompletion([FileEntry(path: "/test/alpha.txt", name: "alpha.txt")])
        XCTAssertEqual(model.selected?.title, "alpha.txt")
        model.updateQuery("find file beta", typed: true)
        XCTAssertEqual(model.results.first?.title, "alpha.txt")
        XCTAssertFalse(model.results.first?.isCurrent ?? true)
        XCTAssertNil(model.selected)
        model.select("file:/test/alpha.txt")
        XCTAssertNil(model.selected)
        // An old callback cannot publish under the new text.
        oldCompletion([FileEntry(path: "/test/wrong.txt", name: "wrong.txt")])
        XCTAssertFalse(model.results.contains { $0.title == "wrong.txt" })
        let secondSearch = expectation(description: "second file request")
        files.onSearch = { secondSearch.fulfill() }
        await fulfillment(of: [secondSearch], timeout: 2)
        files.completion?([FileEntry(path: "/test/beta.txt", name: "beta.txt")])
        XCTAssertEqual(model.selected?.title, "beta.txt")
        XCTAssertTrue(model.results.allSatisfy(\.isCurrent))
    }
    @MainActor func testEmptyQueryWithoutHistoryCollapsesToSearchBar() {
        withModel { model in
            model.preferences.voiceEnabled = true
            model.rebuild()
            XCTAssertTrue(model.rows.isEmpty)
            XCTAssertTrue(model.results.isEmpty)
            XCTAssertTrue(model.isCollapsed)
            XCTAssertNil(model.selected)
            XCTAssertNil(model.notice, "Voice setup belongs to Settings, not the launcher.")
            XCTAssertNil(model.primaryActionTitle)
        }
    }
    @MainActor func testEmptyQueryShowsFavouritesThenRecentOnly() {
        withModel { model in
            let preferences = model.preferences
            preferences.record("window:left-half", query: "left")
            preferences.record("quicklink:gh", query: "gh")
            preferences.record("window:right-half", query: "right")
            preferences.favourites = ["window:right-half", "app:/Missing/Gone.app"]
            model.rebuild()
            XCTAssertEqual(model.results.map(\.id), ["window:right-half", "quicklink:gh", "window:left-half"])
            XCTAssertEqual(model.rows.map(\.id), ["section:Favourites", "window:right-half", "section:Recent", "quicklink:gh", "window:left-half"])
            XCTAssertEqual(model.selected?.id, "window:right-half")
            XCTAssertFalse(model.isCollapsed)
            preferences.favourites = []
            model.rebuild()
            XCTAssertEqual(model.rows.map(\.id), ["window:right-half", "quicklink:gh", "window:left-half"], "One group has no label.")
        }
    }
    @MainActor func testMixedSearchGroupsTopHitFirstAndCapsFiles() async throws {
        let files = InstantFileSearch()
        files.entries = (1...6).map { FileEntry(path: "/tmp/notes/third draft \($0).txt", name: "third draft \($0).txt") }
        let (model, preferences, defaults, suite) = makeModel(jev: HeldJev(), files: files)
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.jevEnabled = false
        model.begin(); defer { model.end() }
        model.updateQuery("third", typed: true)
        try await waitUntil { model.results.contains { $0.group == .files } }
        let top = try XCTUnwrap(model.results.first)
        XCTAssertEqual(model.selected?.id, top.id)
        XCTAssertEqual(model.rows.first?.id, "section:" + top.group.title, "The top hit's group comes first.")
        XCTAssertEqual(model.results.filter { $0.group == .files }.count, LauncherSections.mixedFileLimit)
        // Groups are contiguous, and each has one label.
        let groups = model.results.map(\.group).reduce(into: [LauncherGroup]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(groups.count, Set(groups).count)
        XCTAssertEqual(model.rows.filter { $0.result == nil }.count, groups.count)
        // Arrow keys move over results only, across group boundaries.
        for _ in 0..<model.results.count { model.moveSelection(1) }
        XCTAssertEqual(model.selected?.id, model.results.last?.id)
        model.updateQuery("find file third", typed: true)
        try await waitUntil { model.results.count == 6 }
        XCTAssertTrue(model.rows.allSatisfy { $0.result != nil }, "Files alone need no label.")
    }
    @MainActor func testPrimaryActionFollowsSelection() async throws {
        withModel { model in
            model.updateQuery("2+2", typed: true)
            XCTAssertEqual(model.primaryActionTitle, "Copy")
            model.updateQuery("left half", typed: true)
            XCTAssertEqual(model.primaryActionTitle, "Move Window")
            model.updateQuery("gh swift", typed: true)
            XCTAssertEqual(model.primaryActionTitle, "Search GitHub")
            model.updateQuery("example.com", typed: true)
            XCTAssertEqual(model.primaryActionTitle, "Open URL")
            model.updateQuery("zzqx wvvy", typed: true)
            XCTAssertEqual(model.selected?.id, "web")
            XCTAssertEqual(model.primaryActionTitle, "Search " + model.preferences.webEngine)
        }
        let files = InstantFileSearch()
        files.entries = [FileEntry(path: "/tmp/invoice.pdf", name: "invoice.pdf")]
        let (model, preferences, defaults, suite) = makeModel(jev: HeldJev(), files: files)
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.jevEnabled = false
        model.begin(); defer { model.end() }
        model.updateQuery("find file invoice", typed: true)
        try await waitUntil { model.selected != nil }
        XCTAssertEqual(model.primaryActionTitle, "Open File")
    }
    @MainActor func testSingleLineAccessories() {
        withModel { model in
            model.updateQuery("left half", typed: true)
            XCTAssertEqual(model.selected?.detail, model.targetName)
            XCTAssertEqual(model.selected?.isTwoLine, false)
            model.updateQuery("gh", typed: true)
            XCTAssertEqual(model.selected?.detail, "github.com")
            model.updateQuery("10 km in mi", typed: true)
            XCTAssertEqual(model.selected?.isTwoLine, true)
        }
        let app = AppEntry(path: "/Applications/Safari.app", name: "Safari", bundleID: nil)
        XCTAssertEqual(LauncherModel.appDetail(app, running: true), "Running")
        XCTAssertEqual(LauncherModel.appDetail(app, running: false), "")
    }
    func testFolderDetailKeepsTheLastTwoComponents() {
        let home = "/Users/test"
        XCTAssertEqual(LauncherModel.folderDetail(home + "/Downloads/invoice.pdf", home: home), "~/Downloads")
        XCTAssertEqual(LauncherModel.folderDetail(home + "/Dev/docs/a.md", home: home), "~/Dev/docs")
        XCTAssertEqual(LauncherModel.folderDetail(home + "/Dev/docs/scripts/dist/a.md", home: home), "…/scripts/dist")
        XCTAssertEqual(LauncherModel.folderDetail(home + "/a.md", home: home), "~")
        XCTAssertEqual(LauncherModel.folderDetail("/tmp/a.md", home: home), "/tmp")
        XCTAssertEqual(LauncherModel.folderDetail("/Volumes/Data/a/b/c.txt", home: home), "…/a/b")
        XCTAssertEqual(LauncherModel.folderDetail("/Users/tester/x/y/z.txt", home: home), "…/x/y", "A sibling home is not ~.")
    }
    @MainActor func testCalculatorAndURLDoNotNeedAI() {
        withModel { model in
            model.updateQuery("12 * (8 + 2)", typed: true)
            XCTAssertEqual(model.selected?.id, "calculator")
            XCTAssertEqual(model.selected?.title, "120")
            model.updateQuery("example.com", typed: true)
            XCTAssertEqual(model.selected?.id, "url")
            model.updateQuery("not a url", typed: true)
            XCTAssertFalse(model.results.contains { $0.id == "url" })
        }
    }
    /// One shared word ("2", "in") is not a reason to list a window action beside an answer.
    @MainActor func testAnswerDropsWeakMatchesButKeepsWindowWords() {
        withModel { model in
            model.updateQuery("12 * (8 + 2)", typed: true)
            XCTAssertEqual(model.results.map(\.id), ["calculator", "web"])
            model.updateQuery("10 km in mi", typed: true)
            XCTAssertEqual(model.results.first?.id, "calculator")
            XCTAssertFalse(model.results.contains { $0.id.hasPrefix("window:") })
            // Without an answer, word matches still list window actions.
            model.updateQuery("left", typed: true)
            XCTAssertTrue(model.results.contains { $0.id == "window:left-third" })
        }
    }
    @MainActor func testJevRunsOnShortSingleWordQueries() async throws {
        let jev = HeldJev()
        let (model, _, defaults, suite) = makeModel(jev: jev)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("brow", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        jev.reply(nil)
    }
    @MainActor func testJevSkipsDefiniteAnswersAndPorts() async throws {
        let jev = HeldJev()
        let files = InstantFileSearch()
        let (model, _, defaults, suite) = makeModel(jev: jev, files: files)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        model.updateQuery("12 * (8 + 2)", typed: true)
        try await Task.sleep(nanoseconds: 450_000_000)
        let searchesBefore = files.searches
        model.updateQuery("port 3000", typed: true)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(jev.candidates.isEmpty, "Sums and port lookups do not call Jev.")
        XCTAssertEqual(files.searches, searchesBefore, "Port lookups skip Spotlight.")
    }
    @MainActor func testExactMatchSkipsJev() async throws {
        let jev = HeldJev()
        let (model, _, defaults, suite) = makeModel(jev: jev)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        model.updateQuery("left half", typed: true)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(jev.candidates.isEmpty, "A whole-name match needs no Jev request.")
        XCTAssertEqual(model.selected?.id, "window:left-half")
    }
    @MainActor func testChosenAnswerIsRememberedAndSkipsJevNextTime() async throws {
        let jev = HeldJev()
        let (model, preferences, defaults, suite) = makeModel(jev: jev)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin()
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("make it huge please", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        let id = try XCTUnwrap(jev.candidates.first { $0.title == WindowAction.maximize.title }?.id)
        jev.onChoose = nil
        jev.reply(id)
        try await waitUntil { model.selected?.id == "window:maximize" }
        XCTAssertTrue(model.selected?.detail.hasPrefix("Jev") == true, "The pick is marked.")
        XCTAssertTrue(model.notice?.text.contains("⌘Z") == true)
        // Choosing it teaches the Mac. Window moves need Accessibility, so tests teach it directly.
        model.learnFromExecution(try XCTUnwrap(model.selected))
        model.end()
        XCTAssertEqual(preferences.learned.lookup("make it huge"), "window:maximize")
        let calls = jev.candidates.count
        model.begin(); defer { model.end() }
        model.updateQuery("make it huge", typed: true)
        try await waitUntil { model.selected?.id == "window:maximize" }
        XCTAssertEqual(model.aiStatus, "Remembered")
        XCTAssertEqual(jev.candidates.count, calls, "No second request.")
        XCTAssertTrue(model.undoJevPick())
        XCTAssertNil(preferences.learned.lookup("make it huge"), "Undo forgets the answer.")
        XCTAssertNotEqual(model.results.first?.id, "window:maximize")
    }
    @MainActor func testJevRouteToFilesRewritesTheQuery() async throws {
        let jev = HeldJev()
        let files = InstantFileSearch()
        let (model, _, defaults, suite) = makeModel(jev: jev, files: files)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("photos from this week", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        let id = try XCTUnwrap(jev.candidates.first { $0.title == "Find files" }?.id)
        jev.reply(id)
        try await waitUntil { model.query == "find photos from this week" }
        XCTAssertTrue(model.isFileSearch)
    }
    @MainActor func testJevQuicklinkPickKeepsTheSearchText() async throws {
        let jev = HeldJev()
        let (model, _, defaults, suite) = makeModel(jev: jev)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.begin(); defer { model.end() }
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("github issues about swift ui", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        let id = try XCTUnwrap(jev.candidates.first { $0.title == "Search GitHub" }?.id)
        jev.reply(id)
        try await waitUntil { model.selected?.title == "Search GitHub for issues about swift ui" }
        XCTAssertEqual(model.selected?.id, "quicklink:gh")
    }
    @MainActor func testCustomCommandsReachJevByNameOnly() async throws {
        let jev = HeldJev()
        let (model, preferences, defaults, suite) = makeModel(jev: jev)
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.customCommands = [CustomCommand(name: "Deploy site", command: "cd ~/secret-project && ./deploy.sh")]
        model.begin(); defer { model.end() }
        let asked = expectation(description: "Jev asked")
        jev.onChoose = { asked.fulfill() }
        model.updateQuery("ship the website", typed: true)
        await fulfillment(of: [asked], timeout: 2)
        let candidates = jev.candidates
        let id = try XCTUnwrap(candidates.first { $0.title == "Deploy site" }?.id)
        XCTAssertFalse(candidates.contains { ($0.title + $0.detail).contains("secret") })
        XCTAssertTrue(candidates.contains { $0.title == "Stop the process on a port" })
        XCTAssertTrue(candidates.contains { $0.title == "Empty Trash" })
        XCTAssertLessThanOrEqual(candidates.count, LauncherModel.jevCandidateLimit)
        jev.reply(id)
        try await waitUntil { model.selected?.title == "Deploy site" }
    }
    @MainActor func testDisruptiveCommandsNeedASecondReturn() {
        withModel { model in
            model.updateQuery("empty trash", typed: true)
            XCTAssertEqual(model.selected?.id, "command:empty-trash")
            XCTAssertEqual(model.primaryActionTitle, "Run Command")
            model.execute()
            XCTAssertEqual(model.pendingConfirmID, "command:empty-trash")
            XCTAssertEqual(model.primaryActionTitle, "Confirm")
            XCTAssertTrue(model.notice?.text.contains("Press Return again") == true)
            model.moveSelection(1)
            XCTAssertNil(model.pendingConfirmID, "Moving the selection cancels the confirmation.")
            model.updateQuery("empty trash", typed: true)
            XCTAssertNil(model.pendingConfirmID)
        }
    }
    @MainActor func testLocalSmartRows() {
        withModel { model in
            model.updateQuery("5m tea", typed: true)
            XCTAssertEqual(model.selected?.title, "Start 5 min timer: tea")
            model.updateQuery("search github for swift ui", typed: true)
            XCTAssertEqual(model.selected?.title, "Search GitHub for swift ui")
            model.updateQuery(":tada", typed: true)
            XCTAssertEqual(model.selected?.title.hasPrefix("🎉"), true)
            XCTAssertTrue(model.results.allSatisfy { $0.id.hasPrefix("symbol:") }, "Emoji mode lists emoji only.")
            model.updateQuery("12 * 10", typed: true)
            model.execute()
        }
    }
    @MainActor func testCalculatorAnswerFeedsAns() {
        withModel { model in
            model.updateQuery("12 * 10", typed: true)
            model.execute()
            model.begin()
            model.updateQuery("ans / 4", typed: true)
            XCTAssertEqual(model.selected?.title, "30")
            model.updateQuery("history", typed: true)
            XCTAssertEqual(model.selected?.title, "120")
        }
    }
    @MainActor func testCustomCommandInputAndSnippetsAndWorkflows() {
        let (model, preferences, defaults, suite) = makeModel(jev: HeldJev())
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.jevEnabled = false
        preferences.customCommands = [CustomCommand(name: "Open repo", command: "open ~/Dev/{input}")]
        preferences.snippets = [Snippet(name: "Sign off", text: "Thanks, {clipboard}")]
        preferences.workflows = [Workflow(name: "Coding", steps: [Workflow.Step(kind: .window, value: "left-half")])]
        model.begin(); defer { model.end() }
        model.updateQuery("open repo swift", typed: true)
        XCTAssertEqual(model.selected?.title, "Open repo: swift")
        guard case .custom(_, let input) = model.selected?.action else { return XCTFail("Expected a custom command") }
        XCTAssertEqual(input, "swift")
        model.updateQuery("sign off", typed: true)
        XCTAssertEqual(model.selected?.id.hasPrefix("snippet:"), true)
        model.updateQuery("coding", typed: true)
        XCTAssertEqual(model.selected?.id.hasPrefix("workflow:"), true)
        XCTAssertEqual(Snippet(name: "s", text: "a {clipboard}").expanded(clipboard: "b"), "a b")
    }
    @MainActor func testClipboardPinsAndKinds() {
        let board = FakePasteboard()
        let (model, _, defaults, suite) = makeModel(jev: HeldJev(), board: board)
        defer { defaults.removePersistentDomain(forName: suite) }
        board.copy("https://example.com/page"); model.clipboard.poll()
        board.copy("#ff8800"); model.clipboard.poll()
        board.copy("plain words"); model.clipboard.poll()
        let link = model.clipboard.items.first { $0.text.hasPrefix("https") }!
        model.clipboard.togglePin(link.id)
        model.begin(); defer { model.end() }
        model.updateQuery("clip", typed: true)
        XCTAssertEqual(model.results.first?.title, "https://example.com/page", "Pinned items come first.")
        model.updateQuery("clip colours", typed: true)
        XCTAssertEqual(model.results.map(\.title), ["#ff8800"])
        model.updateQuery("clip links", typed: true)
        XCTAssertEqual(model.results.map(\.title), ["https://example.com/page"])
    }
    @MainActor func testBuiltInCommandsMatchByAlias() {
        withModel { model in
            model.updateQuery("caffeinate", typed: true)
            XCTAssertEqual(model.selected?.id, "command:keep-awake")
            model.updateQuery("dark mode", typed: true)
            XCTAssertEqual(model.selected?.id, "command:dark-mode")
        }
    }
}

@MainActor private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return XCTFail("Condition not met in time") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Jev stand-in whose replies the test releases by hand.
private final class HeldJev: JevChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<String?, Error>] = []
    private var lastCandidates: [JevCandidate] = []
    private var chooseHandler: (@Sendable () -> Void)?
    var onChoose: (@Sendable () -> Void)? {
        get { lock.withLock { chooseHandler } }
        set { lock.withLock { chooseHandler = newValue } }
    }
    var candidates: [JevCandidate] { lock.withLock { lastCandidates } }
    func choose(query: String, candidates: [JevCandidate], apiKey: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let handler = lock.withLock { () -> (@Sendable () -> Void)? in
                pending.append(continuation); lastCandidates = candidates; return chooseHandler
            }
            handler?()
        }
    }
    func reply(_ id: String?) { next()?.resume(returning: id) }
    func fail(_ error: Error) { next()?.resume(throwing: error) }
    private func next() -> CheckedContinuation<String?, Error>? {
        lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    }
}

@MainActor private final class InstantFileSearch: FileSearching {
    var onStatus: ((String) -> Void)?
    var entries: [FileEntry] = []
    var searches = 0
    func stop() {}
    func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void) {
        searches += 1
        completion(entries)
    }
}

@MainActor private final class HeldFileSearch: FileSearching {
    var onStatus: ((String) -> Void)?
    var onSearch: (() -> Void)?
    var completion: (([FileEntry]) -> Void)?
    func stop() {}
    func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void) {
        self.completion = completion
        onSearch?()
    }
}
