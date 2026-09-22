import XCTest
@testable import JevLauncher

final class HotkeySwapTests: XCTestCase {
    private final class Registry {
        var held: [Hotkey: Int] = [:]
        var blocked: Set<Hotkey> = []
        var next = 0
        func register(_ hotkey: Hotkey) -> Int? {
            guard !blocked.contains(hotkey), held[hotkey] == nil else { return nil }
            next += 1; held[hotkey] = next; return next
        }
        func unregister(_ token: Int) { held = held.filter { $0.value != token } }
    }

    func testSuccessfulChangeRegistersBeforeReleasingOld() {
        let registry = Registry()
        let first = HotkeySwap.apply(requested: .controlShiftSpace, active: nil, register: registry.register, unregister: registry.unregister)
        guard case let .switched(hotkey, token) = first else { return XCTFail("Expected registration") }
        let second = HotkeySwap.apply(requested: .optionSpace, active: (hotkey, token), register: { hotkey in
            XCTAssertNotNil(registry.held[.controlShiftSpace], "The old shortcut must still be held while registering the new one.")
            return registry.register(hotkey)
        }, unregister: registry.unregister)
        guard case .switched(.optionSpace, _) = second else { return XCTFail("Expected switch") }
        XCTAssertEqual(Set(registry.held.keys), [.optionSpace])
    }

    func testFailedChangeKeepsOldShortcutForRollback() {
        let registry = Registry()
        guard case let .switched(hotkey, token) = HotkeySwap.apply(requested: .controlShiftSpace, active: nil, register: registry.register, unregister: registry.unregister)
        else { return XCTFail("Expected registration") }
        registry.blocked = [.commandSpace]
        let outcome = HotkeySwap.apply(requested: .commandSpace, active: (hotkey, token), register: registry.register, unregister: registry.unregister)
        guard case .failed(keep: .controlShiftSpace) = outcome else { return XCTFail("Expected rollback to the old shortcut") }
        XCTAssertEqual(Set(registry.held.keys), [.controlShiftSpace])
    }

    func testFirstRegistrationFailureHasNothingToKeep() {
        let registry = Registry(); registry.blocked = [.commandSpace]
        guard case .failed(keep: nil) = HotkeySwap.apply(requested: .commandSpace, active: nil, register: registry.register, unregister: registry.unregister)
        else { return XCTFail("Expected failure") }
    }

    func testSameShortcutIsNotReRegistered() {
        var calls = 0
        let outcome = HotkeySwap.apply(requested: .optionSpace, active: (.optionSpace, 1), register: { _ -> Int? in calls += 1; return 2 }, unregister: { _ in calls += 1 })
        guard case .unchanged = outcome else { return XCTFail("Expected no change") }
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testStoredIntValuesStillLoad() {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2, forKey: "hotkey")
        XCTAssertEqual(Preferences(defaults: defaults).hotkey, .commandSpace)
        defaults.set(9, forKey: "hotkey")
        XCTAssertEqual(Preferences(defaults: defaults).hotkey, .controlShiftSpace)
        let preferences = Preferences(defaults: defaults)
        preferences.hotkey = .optionSpace
        XCTAssertEqual(defaults.integer(forKey: "hotkey"), 1)
    }
}

final class QuicklinkTests: XCTestCase {
    private let links = Quicklink.defaults

    func testKeywordWithTextBuildsEncodedURL() throws {
        let match = try XCTUnwrap(Quicklink.match("GH  swift & ui?", in: links))
        XCTAssertEqual(match.link.keyword, "gh")
        XCTAssertEqual(match.query, "swift & ui?")
        XCTAssertEqual(match.link.url(for: match.query)?.absoluteString, "https://github.com/search?q=swift%20%26%20ui%3F")
    }

    func testKeywordAloneOpensSiteRoot() throws {
        let match = try XCTUnwrap(Quicklink.match("yt", in: links))
        XCTAssertEqual(match.query, "")
        XCTAssertEqual(match.link.url(for: "")?.absoluteString, "https://www.youtube.com/")
    }

    func testNonKeywordDoesNotMatch() {
        XCTAssertNil(Quicklink.match("ghost story", in: links))
        XCTAssertNil(Quicklink.match("", in: links))
    }

    func testValidation() {
        XCTAssertNotNil(Quicklink.validationError(keyword: "gh", template: "https://x.com/?q={query}", existing: links))
        XCTAssertNotNil(Quicklink.validationError(keyword: "two words", template: "https://x.com/?q={query}", existing: []))
        XCTAssertNotNil(Quicklink.validationError(keyword: "x", template: "https://x.com/", existing: []))
        XCTAssertNotNil(Quicklink.validationError(keyword: "x", template: "javascript:alert({query})", existing: []))
        XCTAssertNil(Quicklink.validationError(keyword: "npm", template: "https://www.npmjs.com/search?q={query}", existing: links))
    }

    @MainActor func testDefaultsCanBeDeletedAndStayDeleted() {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Preferences(defaults: defaults).quicklinks, Quicklink.defaults)
        Preferences(defaults: defaults).quicklinks = []
        XCTAssertEqual(Preferences(defaults: defaults).quicklinks, [])
    }
}

@MainActor final class FakePasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    var text: String?
    func string() -> String? { text }
    func copy(_ text: String, types: [String] = ["public.utf8-plain-text"]) { self.text = text; self.types = types; changeCount += 1 }
    func write(_ text: String) -> Int { copy(text); return changeCount }
}

@MainActor final class ClipboardHistoryTests: XCTestCase {
    func testSkipsConcealedTransientAutoGeneratedAndPasswordManagerItems() {
        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"] {
            XCTAssertTrue(ClipboardHistory.shouldSkip(types: ["public.utf8-plain-text", type]), type)
        }
        XCTAssertFalse(ClipboardHistory.shouldSkip(types: ["public.utf8-plain-text"]))
        let board = FakePasteboard(); let history = ClipboardHistory(pasteboard: board)
        history.setEnabled(true)
        board.copy("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]); history.poll()
        XCTAssertTrue(history.items.isEmpty)
    }

    func testDedupesCapsAndIgnoresUnchangedPasteboard() {
        let board = FakePasteboard(); let history = ClipboardHistory(pasteboard: board)
        history.setEnabled(true)
        board.copy("one"); history.poll(); history.poll()
        board.copy("two"); history.poll()
        board.copy("one"); history.poll()
        XCTAssertEqual(history.items.map(\.text), ["one", "two"])
        for index in 0..<60 { board.copy("item \(index)"); history.poll() }
        XCTAssertEqual(history.items.count, ClipboardHistory.limit)
        XCTAssertEqual(history.items.first?.text, "item 59")
    }

    func testRestoreDoesNotAddNewEntry() throws {
        let board = FakePasteboard(); let history = ClipboardHistory(pasteboard: board)
        history.setEnabled(true)
        board.copy("a"); history.poll(); board.copy("b"); history.poll()
        let older = try XCTUnwrap(history.items.last)
        history.restore(older); history.poll()
        XCTAssertEqual(board.text, "a")
        XCTAssertEqual(history.items.map(\.text), ["b", "a"])
    }

    func testDisablingClearsAndIgnoresCopies() {
        let board = FakePasteboard(); let history = ClipboardHistory(pasteboard: board)
        history.setEnabled(true)
        board.copy("a"); history.poll()
        history.setEnabled(false)
        XCTAssertTrue(history.items.isEmpty)
        board.copy("b"); history.poll()
        XCTAssertTrue(history.items.isEmpty)
    }

    func testQueryFilterParsing() {
        XCTAssertEqual(ClipboardHistory.filter(for: "clip"), "")
        XCTAssertEqual(ClipboardHistory.filter(for: "Clipboard "), "")
        XCTAssertEqual(ClipboardHistory.filter(for: "clip invoice 42"), "invoice 42")
        XCTAssertNil(ClipboardHistory.filter(for: "clipper"))
    }
}

final class NamedTargetTests: XCTestCase {
    func testMatchesNameVendorShortNameAndAlias() {
        let apps: [(name: String, aliases: [String])] = [("Safari", []), ("Google Chrome", []), ("Microsoft Word", []), ("Visual Studio Code", ["vsc"])]
        XCTAssertEqual(LauncherModel.namedTargetIndex(in: "safari left half", apps: apps), 0)
        XCTAssertEqual(LauncherModel.namedTargetIndex(in: "chrome right half", apps: apps), 1)
        XCTAssertEqual(LauncherModel.namedTargetIndex(in: "word maximize", apps: apps), 2)
        XCTAssertEqual(LauncherModel.namedTargetIndex(in: "vsc center", apps: apps), 3)
        XCTAssertNil(LauncherModel.namedTargetIndex(in: "left half", apps: apps))
        XCTAssertNil(LauncherModel.namedTargetIndex(in: "safarix left", apps: apps))
    }
}

final class LauncherSectionsTests: XCTestCase {
    private func row(_ id: String, _ action: LauncherResult.Action, _ score: Double) -> LauncherResult {
        LauncherResult(id: id, title: id, detail: "", symbol: "app", action: action, score: score)
    }
    func testTopHitGroupLeadsAndGroupsFollowBestRank() {
        let app = AppEntry(path: "/Applications/A.app", name: "A", bundleID: nil)
        let pane = AppEntry(path: "/System/Applications/System Settings.app", name: "Wi-Fi", bundleID: nil, launchURL: "x-apple.systempreferences:wifi")
        let ranked = [
            row("file:1", .file(FileEntry(path: "/1", name: "1")), 90),
            row("app:a", .app(app), 80),
            row("file:2", .file(FileEntry(path: "/2", name: "2")), 70),
            row("pane", .app(pane), 60),
            row("file:3", .file(FileEntry(path: "/3", name: "3")), 50),
            row("file:4", .file(FileEntry(path: "/4", name: "4")), 40)
        ]
        let groups = LauncherSections.group(ranked, fileLimit: 3)
        XCTAssertEqual(groups.map(\.group), [.files, .applications, .commands])
        XCTAssertEqual(groups.flatMap(\.results).map(\.id), ["file:1", "file:2", "file:3", "app:a", "pane"])
        let rows = LauncherSections.rows(groups)
        XCTAssertEqual(rows.map(\.id).first, "section:Files")
        XCTAssertEqual(rows.filter { $0.result == nil }.count, 3)
        XCTAssertEqual(LauncherSections.rows([groups[0]]).filter { $0.result == nil }.count, 0)
    }
    func testListHeightHandlesMixedRowsAndCaps() {
        let calc = row("calculator", .copy("4"), 1)
        let window = row("window:left-half", .window(.leftHalf, nil), 1)
        let rows: [LauncherRow] = [.section(.commands), .result(calc), .result(window)]
        let spacing = LauncherMetrics.rowSpacing
        XCTAssertEqual(LauncherSections.listHeight(rows),
                       LauncherMetrics.sectionHeight + LauncherMetrics.tallCellHeight + LauncherMetrics.cellHeight + 3 * spacing)
        let many = (0..<20).map { LauncherRow.result(row("r\($0)", .window(.leftHalf, nil), 1)) }
        XCTAssertEqual(LauncherSections.listHeight(many), LauncherMetrics.maxListHeight)
        // A capped list ends on a whole result row, never on a section label.
        let pitch = LauncherMetrics.cellHeight + spacing
        let fill = Array(many.prefix(LauncherMetrics.maxVisibleRows - 1))
        let dangling: [LauncherRow] = fill + [.section(.files), .result(row("file:x", .file(FileEntry(path: "/x", name: "x")), 1))]
        XCTAssertEqual(LauncherSections.listHeight(dangling), CGFloat(fill.count) * pitch)
    }
}
