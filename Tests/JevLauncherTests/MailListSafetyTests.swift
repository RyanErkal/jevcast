import AppKit
import SwiftUI
import XCTest
import LauncherCore
@testable import JevLauncher

/// What the list's actions may do to mail, on invented demo mail: deletes in Trash, Delete All
/// from a sender after the list changed, Undo while a move still runs, the mailbox rules behind
/// every key and menu, and which note takes ⌘Z. Deletes go to a recording fake; nothing reaches Mail.
@MainActor
final class MailListSafetyTests: XCTestCase {
    private var deleted: [(row: Int64, permanent: Bool)] = []

    private static let inbox = MailMailbox(rowID: 1, url: "imap://demo/INBOX", unread: 1, total: 2, serverRole: .inbox)
    private static let trash = MailMailbox(rowID: 2, url: "imap://demo/Trash", unread: 0, total: 0, serverRole: .trash)
    private static let sent = MailMailbox(rowID: 3, url: "imap://demo/Sent", unread: 0, total: 0, serverRole: .sent)
    private static let drafts = MailMailbox(rowID: 4, url: "imap://demo/Drafts", unread: 0, total: 0, serverRole: .drafts)

    private static let start = Date()

    private static func message(_ row: Int64, box: Int64 = 1, sender: String = "Ada", address: String = "ada@example.com",
                                read: Bool = false, flagged: Bool = false, subject: String? = nil, conversation: Int64? = nil) -> MailSummary {
        MailSummary(rowID: row, mailbox: box, subject: subject ?? "Subject \(row)", senderName: sender, senderAddress: address, snippet: "",
                    date: start.addingTimeInterval(Double(-row * 60)), read: read, flagged: flagged, conversation: conversation ?? row)
    }

    /// Runs `body` with Jevcast's own accounts as the mail source, where a delete in Trash is for
    /// good. No engine runs, and the deletes go to the test's fake.
    private func withJevcastAccounts(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: MailBackend.key)
        defaults.set(MailBackend.jevcast.rawValue, forKey: MailBackend.key)
        defer {
            if let previous { defaults.set(previous, forKey: MailBackend.key) } else { defaults.removeObject(forKey: MailBackend.key) }
        }
        try await body()
    }

    private func demo(_ messages: [MailSummary], delete: ((MailSummary) async throws -> Void)? = nil) -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              setRead: { _, _, _, _ in }, deleteMessage: { [weak self] message, _, permanent in
                                  try await delete?(message)
                                  await MainActor.run { self?.deleted.append((message.rowID, permanent)) }
                              }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: [Self.inbox, Self.trash, Self.sent, Self.drafts], messages: messages)
        model.serverDrafts = MailServerDraftCoordinator(model: model, save: nil, remove: nil, cleanupStore: nil)
        model.select(messages.first?.rowID, byUser: false)
        return model
    }

    // MARK: F1: the list's own selection updates

    func testOnlyTheUsersSelectionPicksARow() throws {
        // A window of the test's own with the list's table on the left and another view beside it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // As under a SwiftUI List: a table with a column, in a scroll view.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let table = NSTableView(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        scroll.documentView = table
        let other = NSTextField(frame: NSRect(x: 220, y: 0, width: 160, height: 30))
        content.addSubview(scroll); content.addSubview(other)
        window.contentView = content
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func click(at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func key() throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        }
        let inList = try click(at: NSPoint(x: 50, y: 100)), elsewhere = try click(at: NSPoint(x: 300, y: 10))
        XCTAssertTrue(MailMessageList.isUserSelection([2], current: [1], event: inList, table: table), "A click on another row picks it")
        XCTAssertFalse(MailMessageList.isUserSelection([1], current: [1], event: inList, table: table), "The table writing back what it shows")
        XCTAssertFalse(MailMessageList.isUserSelection([2], current: [1], event: nil, table: table), "A change while it lays out, with no click or key")
        XCTAssertFalse(MailMessageList.isUserSelection([2], current: [1], event: elsewhere, table: table), "A click elsewhere in the app")
        XCTAssertFalse(MailMessageList.isUserSelection([2], current: [1], event: inList, table: nil), "No table found yet")
        window.makeFirstResponder(other)
        XCTAssertFalse(MailMessageList.isUserSelection([2], current: [1], event: try key(), table: table), "A key in another field")
        window.makeFirstResponder(table)
        XCTAssertTrue(MailMessageList.isUserSelection([2], current: [1], event: try key(), table: table), "A key in the list")
    }

    // MARK: R9: a click on the row already selected

    /// The list sees a plain click on its one selected row, which changes no selection. ⇧- and
    /// ⌘-clicks, a click on another row, and a click with several rows selected are left to the
    /// table's own selection.
    func testAPlainClickOnTheSelectedRowIsSeen() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let table = NSTableView(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        let rows = Rows()
        table.dataSource = rows
        table.rowHeight = 20
        scroll.documentView = table
        window.contentView = scroll
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        table.reloadData()
        table.selectRowIndexes([1], byExtendingSelection: false)
        func click(row: Int, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let center = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: center.midX, y: center.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertTrue(MailListTable.isPlainClickOnTheSelectedRow(try click(row: 1), in: table))
        XCTAssertFalse(MailListTable.isPlainClickOnTheSelectedRow(try click(row: 2), in: table), "Another row: the selection changes")
        XCTAssertFalse(MailListTable.isPlainClickOnTheSelectedRow(try click(row: 1, .command), in: table), "⌘-click only selects")
        XCTAssertFalse(MailListTable.isPlainClickOnTheSelectedRow(try click(row: 1, .shift), in: table), "⇧-click only selects")
        table.selectRowIndexes([1, 2], byExtendingSelection: false)
        XCTAssertFalse(MailListTable.isPlainClickOnTheSelectedRow(try click(row: 1), in: table), "Several rows: the click narrows them")
    }

    func testAClickOnTheSelectedRowShowsItAgain() throws {
        let details = MailSnapshots.accountConnection(signIn: true)
        let model = try XCTUnwrap(details.mail)
        let row = try XCTUnwrap(model.selectedConversationRowID)
        model.selectConversationRows([row])
        XCTAssertEqual(details.accountDetailsID, "demo")
        details.activate(row)
        XCTAssertNil(details.accountDetailsID, "The connection details close and the message shows")

        let blocked = MailSnapshots.blockedDraft(signInRefused: false)
        let mail = try XCTUnwrap(blocked.mail)
        let focused = try XCTUnwrap(mail.selectedConversationRowID)
        mail.selectConversationRows([focused])
        XCTAssertTrue(blocked.composing)
        blocked.activate(focused)
        XCTAssertFalse(blocked.composing, "The draft steps aside and is kept")
        XCTAssertNotNil(mail.draft)
    }

    /// The table writes its selection back as it lays out. That must not close the connection
    /// details or set a draft aside, as `pick` does for a click.
    func testConnectionDetailsAndABlockedDraftStayWhileTheListLaysOut() async throws {
        let details = MailSnapshots.accountConnection(signIn: true)
        XCTAssertEqual(details.accountDetailsID, "demo")
        let blocked = MailSnapshots.blockedDraft(signInRefused: false)
        XCTAssertTrue(blocked.composing)
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        for page in [details, blocked] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView: page.content().frame(width: 1320, height: 820))
            window.orderFrontRegardless()
            windows.append(window)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(details.accountDetailsID, "demo", "The connection details stay on screen")
        XCTAssertTrue(blocked.composing, "The blocked draft stays on screen")
        XCTAssertNil(blocked.mail?.draftNote, "Nothing said the draft was set aside")
    }

    // MARK: F2: several rows in Trash

    func testSeveralRowsInTrashAreNeverDeletedOneByOne() async throws {
        let model = demo([Self.message(10, box: 2), Self.message(11, box: 2), Self.message(12, box: 2)])
        let page = MailPage(mail: model)
        model.selectConversationRows([10, 11])
        model.delete()
        XCTAssertEqual(model.banner, "Select one message to delete it for good.")
        model.banner = nil
        XCTAssertTrue(page.handle(.delete), "⌫ is taken")
        XCTAssertEqual(model.banner, "Select one message to delete it for good.")
        model.runRowAction(.delete, on: [10, 11], page: page)
        model.bulk(.trash)
        await model.waitForActions()
        XCTAssertTrue(deleted.isEmpty, "Nothing was deleted from any entry point")
        XCTAssertEqual(model.messages.count, 3)

        model.selectConversationRows([11])
        model.select(11, byUser: true)
        model.delete()
        await model.waitForActions()
        XCTAssertEqual(deleted.map(\.row), [11], "One selected message still goes")
    }

    // MARK: T1: only Delete's own keys delete in Trash

    /// The panel's key path, as the app routes a key: the launcher, then Mail. No window, no posted keys.
    private func panel(_ page: MailPage) -> (LauncherModel, () -> Void) {
        let suite = "MailListSafetyTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        let launcher = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false),
                                     keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        launcher.page = page
        return (launcher, { defaults.removePersistentDomain(forName: suite) })
    }

    private static func deleteKey(_ flags: NSEvent.ModifierFlags, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: repeating, keyCode: 51)!
    }

    func testASecondDiscardKeyAfterAnEmptyDraftClosedNeverDeletesInTrash() async {
        await withJevcastAccounts {
            let model = demo([Self.message(10, box: 2), Self.message(11, box: 2)])
            let page = MailPage(mail: model)
            let (launcher, done) = panel(page); defer { done() }
            XCTAssertTrue(launcher.handleViewKey(MailComposeRig.key("n", .command)), "⌘N opens a new message")
            XCTAssertTrue(page.composing)
            XCTAssertTrue(launcher.handleViewKey(Self.deleteKey([.command, .shift])), "The first ⇧⌘⌫ closes the untouched draft")
            XCTAssertNil(model.draft)
            XCTAssertFalse(page.composing)
            XCTAssertTrue(launcher.handleViewKey(Self.deleteKey([.command, .shift])), "Mail takes the second press")
            XCTAssertTrue(launcher.handleViewKey(Self.deleteKey([.command, .shift], repeating: true)))
            await model.waitForActions()
            XCTAssertTrue(deleted.isEmpty, "Nothing was deleted for good")
            XCTAssertEqual(model.messages.count, 2)
        }
    }

    func testOnlyDeleteAndCommandDeleteDeleteAMessageInTrash() async {
        await withJevcastAccounts {
            let model = demo([Self.message(10, box: 2), Self.message(11, box: 2)])
            let page = MailPage(mail: model)
            let (launcher, done) = panel(page); defer { done() }
            for flags: NSEvent.ModifierFlags in [[.command, .shift], .option, .control, .shift, [.command, .option], [.command, .control]] {
                _ = launcher.handleViewKey(Self.deleteKey(flags))
            }
            // A held key never deletes, also ⌫ and ⌘⌫.
            XCTAssertTrue(launcher.handleViewKey(Self.deleteKey([], repeating: true)))
            XCTAssertTrue(launcher.handleViewKey(Self.deleteKey(.command, repeating: true)))
            await model.waitForActions()
            XCTAssertTrue(deleted.isEmpty, "⇧⌘⌫, ⌥⌫, ⌃⌫, ⇧⌫, and held keys never delete")

            XCTAssertTrue(launcher.handleViewKey(Self.deleteKey([])), "One press of ⌫ deletes")
            await model.waitForActions()
            XCTAssertEqual(deleted.map(\.row), [10])
            XCTAssertTrue(deleted.allSatisfy(\.permanent))
        }
    }

    func testSeveralRowsWithOneInTrashAreNotDeleted() async {
        let model = demo([Self.message(10), Self.message(11, box: 2)])
        model.selectConversationRows([10, 11])
        model.select(10, byUser: false)
        model.delete()
        await model.waitForActions()
        XCTAssertTrue(deleted.isEmpty, "A Trash row in the selection would be deleted for good")
        XCTAssertEqual(model.banner, "Select one message to delete it for good.")
    }

    // MARK: F3: Delete All from a sender after the list changed

    func testDeleteAllFromASenderMovesOnlyWhatStillMatches() async throws {
        let model = demo([Self.message(10), Self.message(11), Self.message(12), Self.message(13, sender: "Bo", address: "bo@example.com")])
        model.deleteAllFromSender()
        XCTAssertEqual(model.senderDeleteRequest?.count, 3)
        // Meanwhile the index changed: row 11 is now someone else's message, and 12 went to Trash.
        let now = [Self.message(10), Self.message(11, sender: "Cy", address: "cy@example.com"), Self.message(12, box: 2),
                   Self.message(13, sender: "Bo", address: "bo@example.com")]
        model.readRows = { ids in now.filter { ids.contains($0.rowID) } }
        await model.confirmDeleteAllFromSender()?.value
        XCTAssertEqual(model.lastChange?.title, "Moved 1 of 3 messages from Ada to Trash", "The note says the real count")
        await model.waitForActions()
        XCTAssertEqual(deleted.map(\.row), [10])
        XCTAssertFalse(deleted.contains { $0.permanent }, "Delete All from a sender never deletes for good")
    }

    /// Apple Mail's message key can be the row number alone. A row the index gave to another
    /// message from the same sender, in the same mailbox, is read again and skipped.
    func testDeleteAllFromASenderSkipsARowNowHoldingAnotherMessage() async {
        let model = demo([Self.message(10), Self.message(11)])
        model.deleteAllFromSender()
        XCTAssertEqual(model.senderDeleteRequest?.count, 2)
        // The list on screen still shows the counted rows; the index has a newer message in row 11.
        let reused = MailSummary(rowID: 11, mailbox: 1, subject: "Another subject", senderName: "Ada", senderAddress: "ada@example.com",
                                 snippet: "", date: Self.start.addingTimeInterval(3600), read: false, flagged: false, conversation: 11)
        model.readRows = { ids in [Self.message(10), reused].filter { ids.contains($0.rowID) } }
        await model.confirmDeleteAllFromSender()?.value
        await model.waitForActions()
        XCTAssertEqual(deleted.map(\.row), [10], "Only the message that was counted moves")

        // When the index cannot be read, nothing moves.
        deleted = []
        model.deleteAllFromSender()
        model.readRows = { _ in nil }
        await model.confirmDeleteAllFromSender()?.value
        await model.waitForActions()
        XCTAssertTrue(deleted.isEmpty)
    }

    func testDeleteAllFromASenderNeverCountsTrash() {
        let model = demo([Self.message(10), Self.message(11, box: 2)])
        model.deleteAllFromSender()
        XCTAssertEqual(model.senderDeleteRequest?.rowIDs, [10])
    }

    // MARK: F6: Undo while the move still runs

    func testUndoAtOnceStillPutsBackWhatMovesLater() async throws {
        let gate = Gate()
        let model = demo([Self.message(10), Self.message(11)]) { _ in await gate.wait() }
        var movedBack: [Int64] = []
        model.moveBackAction = { snapshot, _, _ in await MainActor.run { movedBack.append(snapshot.message.rowID) } }
        model.delete(10)
        try await waitUntil { await gate.isWaiting }
        model.undoLastChange()
        XCTAssertNil(model.lastChange, "The note goes at once")
        await gate.open()
        try await waitUntil { await MainActor.run { !movedBack.isEmpty } }
        XCTAssertEqual(movedBack, [10], "Undo learns what moved after it was pressed")
        try await waitUntil { await MainActor.run { model.changeProgress.isEmpty } }
    }

    // MARK: R7: an Undo you pressed is never dropped

    func testUndoPressedDuringASlowMoveWaitsForABulkActionThenRuns() async throws {
        let gate = Gate(), bulkGate = Gate()
        let model = demo([Self.message(10), Self.message(11)]) { _ in await gate.wait() }
        var movedBack: [Int64] = []
        model.moveBackAction = { snapshot, _, _ in await MainActor.run { movedBack.append(snapshot.message.rowID) } }
        model.delete(10)
        try await waitUntil { await gate.isWaiting }
        model.undoLastChange()
        // A bulk action starts and is still running when the move finishes.
        model.bulkBusy = true
        model.bulkWork = Task { @MainActor in await bulkGate.wait(); model.bulkBusy = false }
        await gate.open()
        await model.waitForActions()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(movedBack.isEmpty, "It waits behind the bulk action")
        XCTAssertEqual(model.changeProgress.count, 1, "Its record is kept meanwhile")
        await bulkGate.open()
        try await waitUntil { await MainActor.run { movedBack == [10] } }
        XCTAssertEqual(movedBack, [10], "Then it runs")
    }

    func testUndoStaysForTheMessagesThatMovedWhenOthersFailed() async {
        let model = demo([Self.message(10), Self.message(11), Self.message(12)]) { message in
            if message.rowID == 11 { throw LauncherError("Server refused one") }
        }
        model.selectConversationRows([10, 11, 12])
        model.delete()
        await model.waitForActions()
        XCTAssertEqual(Set(model.lastChange?.moved.map(\.message.rowID) ?? []), [10, 12], "Undo keeps the two that moved")
        XCTAssertTrue(model.banner?.contains("Server refused one") == true)
    }

    // MARK: F7: bulk Undo restores each message's own state

    func testBulkUndoRestoresEachMessagesOwnState() {
        XCTAssertNil(MailModel.undoneState(true, was: true), "A message that was already read stays read")
        XCTAssertEqual(MailModel.undoneState(true, was: false), false, "One that was unread goes back to unread")
        XCTAssertNil(MailModel.undoneState(false, was: false))
        XCTAssertEqual(MailModel.undoneState(false, was: true), true)
    }

    // MARK: F13: one rule for every way in

    func testKeysFollowTheMailboxRules() throws {
        var account = try XCTUnwrap(NativeMailAccount.preset(.gmail, name: "Alex", email: "alex@example.com"))
        account.id = "demo"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-rules-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = demo([Self.message(10, box: 3), Self.message(11, box: 4), Self.message(12, box: 2), Self.message(13, box: 2)])
        let page = MailPage(mail: model, features: MailFeatureCenter(directory: directory, defaults: nil, accounts: [account]))

        model.select(10, byUser: true)
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("s", [.command, .control])))
        XCTAssertFalse(model.snoozeEditorOpen, "Sent has no Snooze, also by its key")
        XCTAssertEqual(model.banner, "Snooze is not available in Sent.")

        model.select(11, byUser: true)
        model.banner = nil
        XCTAssertTrue(page.handleEvent(MailComposeRig.key("e", .command)))
        XCTAssertEqual(model.banner, "Archive is not available in Drafts.")
        model.selectConversationRows([11])
        model.bulk(.archive)
        XCTAssertEqual(model.banner, "Archive is not available for these messages.", "The list's ⋯ menu follows the same rule")

        model.selectConversationRows([12, 13])
        model.bulk(.trash)
        XCTAssertEqual(model.banner, "Select one message to delete it for good.", "Several Trash rows are not moved to Trash again")
        XCTAssertFalse(model.bulkBusy)
        XCTAssertEqual(model.bulkRefusal(.flag(true)), nil, "Flag is allowed in Trash")
    }

    // MARK: R1: a delete for good acts only on the row you chose

    func testASyncThatRemovesTheFocusedRowKeepsTheFocusInsideTheSelection() async {
        await withJevcastAccounts {
            let model = demo([Self.message(10, box: 2), Self.message(11, box: 2), Self.message(12, box: 2), Self.message(13, box: 2)])
            model.selectConversationRows([11, 12, 13])
            model.select(11, byUser: false)
            // A sync removes the focused row.
            model.install([Self.message(10, box: 2), Self.message(12, box: 2), Self.message(13, box: 2)])
            XCTAssertTrue(model.selectedConversationRowIDs.contains(model.selectedID ?? -1), "The focus stays inside the selection")
            model.delete()
            await model.waitForActions()
            XCTAssertTrue(deleted.isEmpty, "Several rows are still selected: nothing is deleted for good")

            // Two rows, then one goes: the one left is both the selection and the focus.
            model.selectConversationRows([12, 13])
            model.select(12, byUser: false)
            model.install([Self.message(10, box: 2), Self.message(13, box: 2)])
            XCTAssertEqual(model.selectedID, 13, "Never the unrelated first row")
            model.delete()
            await model.waitForActions()
            XCTAssertEqual(deleted.map(\.row), [13])
            XCTAssertFalse(deleted.contains { $0.row == 10 }, "The row nobody selected stays")
        }
    }

    func testTheHoverDeleteAndItsSpokenActionFollowTheSelectionInTrash() async {
        await withJevcastAccounts {
            let model = demo([Self.message(10, box: 2), Self.message(11, box: 2), Self.message(12, box: 2)])
            model.selectConversationRows([10, 11])
            model.select(10, byUser: false)
            model.runRowAction(.delete, on: [12], page: nil)
            model.runRowAction(.delete, on: [11], page: nil)
            await model.waitForActions()
            XCTAssertTrue(deleted.isEmpty, "With several rows selected, no single row goes for good")
            XCTAssertEqual(model.banner, "Select one message to delete it for good.")

            // One row on screen: Delete on another row deletes that row, and only it.
            model.selectConversationRows([10])
            model.runRowAction(.delete, on: [12], page: nil)
            await model.waitForActions()
            XCTAssertEqual(deleted.map(\.row), [12])
            XCTAssertTrue(deleted.allSatisfy(\.permanent))
        }
    }

    // MARK: R10: one rule for the reader's bar and for several rows

    func testTheReaderBarHidesSnoozeWhereTheMailboxRefusesIt() throws {
        var account = try XCTUnwrap(NativeMailAccount.preset(.gmail, name: "Alex", email: "alex@example.com"))
        account.id = "demo"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-bar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let features = MailFeatureCenter(directory: directory, defaults: nil, accounts: [account])
        let model = demo([Self.message(10, box: 3), Self.message(11)])
        model.select(10, byUser: true)
        XCTAssertFalse(model.readerToolbarItems(features: features, canExpand: true).contains(.snooze), "Sent has no Snooze")
        model.select(11, byUser: true)
        XCTAssertTrue(model.readerToolbarItems(features: features, canExpand: true).contains(.snooze), "Inbox has Snooze")
    }

    func testSeveralRowsOfferOnlyWhatEveryMessageInThemAllows() {
        // Row 10's conversation has an older reply (11) in Trash; row 12 is in the Inbox.
        let model = demo([Self.message(10, conversation: 100), Self.message(11, box: 2, conversation: 100), Self.message(12)])
        XCTAssertEqual(model.conversationGroups.count, 2)
        let context = model.rowMenuContext([10, 12], features: nil)
        XCTAssertFalse(MailRowMenu.bulkActions(context).contains(.delete), "A reply in Trash would be deleted for good")
        XCTAssertFalse(MailRowMenu.bulkActions(context).contains(.archive), "Trash has no Archive")
        model.selectConversationRows([10, 12])
        XCTAssertNotNil(model.bulkRefusal(.trash), "What the menu offers is what runs")
    }

    func testOpeningAMessageClearsTheSearchAndClosesConnectionDetails() {
        let model = demo([Self.message(10), Self.message(11)])
        var cleared = 0
        let page = MailPage(mail: model, clearQuery: { cleared += 1; model.search = "" })
        page.accountDetailsID = "demo"
        model.search = "invoice"
        page.show(11)
        XCTAssertNil(page.accountDetailsID)
        XCTAssertEqual(cleared, 1, "The launcher's search text goes, so it cannot hide the message")
        XCTAssertEqual(model.search, "")
    }

    // MARK: R11 and R13

    func testCommandZIsNotShownWhileATextBoxHasTheKeys() {
        XCTAssertTrue(MailBanner.showsUndoKey(.change, on: .change, typing: false))
        XCTAssertFalse(MailBanner.showsUndoKey(.change, on: .change, typing: true), "⌘Z is the text's own undo while writing")
        XCTAssertFalse(MailBanner.showsUndoKey(.send, on: .change, typing: false))
        XCTAssertFalse(MailBanner.showsUndoKey(.send, on: .send, typing: true))
    }

    func testARowDrawsAgainWhenTheDayChanges() {
        let model = demo([Self.message(10)])
        let conversation = model.conversationGroups[0]
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let before = MailConversationSummaryRow(conversation: conversation, day: today)
        XCTAssertEqual(before, MailConversationSummaryRow(conversation: conversation, day: today))
        XCTAssertNotEqual(before, MailConversationSummaryRow(conversation: conversation, day: tomorrow), "After midnight the date reads again")
    }

    // MARK: F16 and F19

    func testCommandZShowsOnlyOnTheNoteItUndoes() {
        let model = demo([Self.message(10), Self.message(11)])
        XCTAssertEqual(model.undoKeyTarget, .none)
        model.delete(10)
        XCTAssertEqual(model.undoKeyTarget, .change)
        model.pendingSend = MailModel.Draft(to: "sam@example.com", subject: "Hi", body: "Hi")
        XCTAssertEqual(model.undoKeyTarget, .send, "While a send waits, ⌘Z undoes the send")
        model.pendingSend = nil
    }

    func testOnlyAnAppleMailCheckSetsItsTime() {
        let model = demo([Self.message(10)])
        let now = Date()
        model.recordMailCheck(at: now, native: true)
        XCTAssertNil(model.lastAppleMailCheck, "A check of Jevcast's own accounts is not Apple Mail's")
        model.recordMailCheck(at: now, native: false)
        XCTAssertEqual(model.lastAppleMailCheck, now)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while await !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let met = await condition()
        XCTAssertTrue(met, "Timed out")
    }
}

/// Holds a fake server action until the test lets it go.
private actor Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    var isWaiting: Bool { waiting != nil }
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func open() {
        opened = true
        waiting?.resume(); waiting = nil
    }
}

/// Five rows for a plain table in a test window.
private final class Rows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 5 }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Row \(row)" }
}
