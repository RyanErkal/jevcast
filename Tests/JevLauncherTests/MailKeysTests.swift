import AppKit
import XCTest
import LauncherCore
@testable import JevLauncher

/// Mail keys that act only with a modifier or with an empty filter, on invented demo mail.
/// Nothing here reaches Mail: the demo account has no Archive mailbox, so Archive only reports that.
@MainActor
final class MailKeysTests: XCTestCase {
    private var savedZoom: Any?

    override func setUp() async throws { savedZoom = UserDefaults.standard.object(forKey: MailReading.zoomKey) }
    override func tearDown() async throws {
        if let savedZoom { UserDefaults.standard.set(savedZoom, forKey: MailReading.zoomKey) }
        else { UserDefaults.standard.removeObject(forKey: MailReading.zoomKey) }
    }

    private func demo() -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              setRead: { _, _, _, _ in }, deleteMessage: { _, _, _ in }, draftStore: nil, mailDefaults: nil)
        let inbox = MailMailbox(rowID: 1, url: "imap://demo/INBOX", unread: 1, total: 2, serverRole: .inbox)
        let messages = (1...3).map { index in
            MailSummary(rowID: Int64(index), mailbox: 1, subject: "Subject \(index)", senderName: "Ada", senderAddress: "ada@example.com",
                        snippet: "", date: Date().addingTimeInterval(Double(-index * 60)), read: false, flagged: false, conversation: Int64(index))
        }
        model.installDemo(mailboxes: [inbox], messages: messages)
        // No server drafts: nothing here saves to a server or reads the composition folder.
        model.serverDrafts = MailServerDraftCoordinator(model: model, save: nil, remove: nil, cleanupStore: nil)
        model.select(1, byUser: false)
        return model
    }

    func testCommandEArchivesAndControlCommandAStillDoes() {
        let model = demo()
        let page = MailPage(mail: model)
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("e")), "Plain E types in the filter")
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("e", .command)))
        XCTAssertEqual(model.banner, "This account has no Archive mailbox.", "⌘E runs Archive")
        model.banner = nil
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("a", [.command, .control])))
        XCTAssertEqual(model.banner, "This account has no Archive mailbox.", "⌃⌘A still runs Archive")
    }

    func testCommandEStaysWithSelectedTextInTheFilter() {
        let model = demo()
        let page = MailPage(mail: model)
        page.hasTextSelection = { true }
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("e", .command)), "⌘E is the text's Use Selection for Find")
        XCTAssertNil(model.banner, "Nothing was archived")
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("a", [.command, .control])), "⌃⌘A always archives")
        XCTAssertEqual(model.banner, "This account has no Archive mailbox.")

        let editor = NSTextView()
        editor.string = "ada lovelace"
        XCTAssertFalse(MailPage.selectsText(editor))
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertTrue(MailPage.selectsText(editor))
        XCTAssertFalse(MailPage.selectsText(nil))
    }

    func testScrollingOrClickingInTheMessageCountsAsReading() throws {
        let inside = NSRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertTrue(MailReaderActivity.counts(.scrollWheel, at: NSPoint(x: 10, y: 10), in: inside))
        XCTAssertTrue(MailReaderActivity.counts(.leftMouseDown, at: NSPoint(x: 10, y: 10), in: inside))
        XCTAssertFalse(MailReaderActivity.counts(.scrollWheel, at: NSPoint(x: 400, y: 10), in: inside), "Outside the reader")
        XCTAssertFalse(MailReaderActivity.counts(.mouseMoved, at: NSPoint(x: 10, y: 10), in: inside), "Moving the pointer is not using it")

        let model = demo()
        XCTAssertFalse(model.selectionIsUsers, "The model chose the first message")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true
        defer { window.orderOut(nil) }
        let watcher = MailReaderActivity.Watcher(frame: NSRect(x: 50, y: 50, width: 200, height: 150))
        watcher.onAction = { model.noteUserAction() }
        window.contentView?.addSubview(watcher)
        window.orderFrontRegardless()
        func click(_ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        watcher.notice(try click(NSPoint(x: 10, y: 10)))
        XCTAssertFalse(model.selectionIsUsers, "A click beside the reader does not count")
        watcher.notice(try click(NSPoint(x: 100, y: 100)))
        XCTAssertTrue(model.selectionIsUsers, "A click in the message counts as acting on it")
        watcher.removeFromSuperview()
    }

    func testControlCommandSOpensSnoozeForJevcastAccounts() throws {
        let model = demo()
        let without = MailPage(mail: model)
        XCTAssertTrue(without.handleEvent(MailComposeRig.key("s", [.command, .control])))
        XCTAssertFalse(model.snoozeEditorOpen)
        XCTAssertEqual(model.banner, "Snooze works with the accounts you add in Settings › Mail.")

        var account = try XCTUnwrap(NativeMailAccount.preset(.gmail, name: "Alex", email: "alex@example.com"))
        account.id = "demo"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-keys-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = MailPage(mail: model, features: MailFeatureCenter(directory: directory, defaults: nil, accounts: [account]))
        page.tool = .snoozed
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("s", [.command, .control])), "A tool on screen takes the keys")
        page.tool = nil
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("s", [.command, .control])))
        XCTAssertTrue(model.snoozeEditorOpen)
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("s", .command)), "⌘S is not Snooze")
    }

    func testZoomKeysChangeTheReadersTextSize() {
        let model = demo()
        let page = MailPage(mail: model)
        MailReading.zoom = 1
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("=", .command)))
        XCTAssertEqual(MailReading.zoom, 1.25)
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("+", [.command, .shift])))
        XCTAssertEqual(MailReading.zoom, 1.5)
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("=", .command)))
        XCTAssertEqual(MailReading.zoom, 1.5, "The size stops at the largest step")
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("-", .command)))
        XCTAssertEqual(MailReading.zoom, 1.25)
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("0", .command)))
        XCTAssertEqual(MailReading.zoom, 1)
        for _ in 0..<5 { _ = page.handleEvent(MailComposeRig.key("-", .command)) }
        XCTAssertEqual(MailReading.zoom, 0.75, "The size stops at the smallest step")
        XCTAssertFalse(page.handleEvent(MailComposeRig.key("-")), "A plain minus types in the filter")
        XCTAssertEqual(UserDefaults.standard.double(forKey: MailReading.zoomKey), 0.75, "The reader's control reads the same setting")
    }

    func testSpacePagesOnlyWithAnEmptyFilterAndCountsAsReading() {
        let model = demo()
        let page = MailPage(mail: model)
        XCTAssertFalse(model.selectionIsUsers, "The model chose the first message")
        XCTAssertTrue(page.handleEvent(MailComposeRig.key(" ")))
        XCTAssertTrue(model.selectionIsUsers, "Space scrolls the message, which counts as acting on it")
        XCTAssertFalse(page.expanded, "Space no longer expands; Return does")
        XCTAssertTrue(page.handleEvent(MailComposeRig.key(" ", .shift)), "⇧Space pages up")
        model.search = "ada"
        XCTAssertFalse(page.handleEvent(MailComposeRig.key(" ")), "With text in the filter, Space types")
        XCTAssertFalse(page.handleEvent(MailComposeRig.key(" ", .command)))
    }

    func testTheSidebarStaysAsYouLeftIt() throws {
        let suite = "jevcast-mail-sidebar-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = demo()
        XCTAssertTrue(MailPage(mail: model, sidebarDefaults: defaults).showsSidebar, "On by default")
        MailPage(mail: model, sidebarDefaults: defaults).showsSidebar = false
        XCTAssertFalse(MailPage(mail: model, sidebarDefaults: defaults).showsSidebar, "A new page, as after a restart, keeps it hidden")
        XCTAssertTrue(MailPage(mail: model).showsSidebar, "Snapshots and tests keep nothing")
    }

    func testOpeningMailKeepsThePlaceAndAKeptDraftStaysClosed() {
        let model = demo()
        model.place = .flagged
        model.compose(to: "ann@example.com")
        model.draft?.body = "Kept"
        let first = MailPage(mail: model)
        XCTAssertTrue(first.back())
        XCTAssertFalse(first.composing)
        // The launcher makes a new page each time Mail opens.
        let next = MailPage(mail: model)
        next.resume()
        XCTAssertEqual(model.place, .flagged, "Mail opens on the mailbox you left")
        XCTAssertFalse(next.composing, "A draft you closed stays closed")
        XCTAssertEqual(model.draft?.body, "Kept")
    }
}
