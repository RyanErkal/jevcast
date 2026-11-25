import XCTest
import LauncherCore
@testable import JevLauncher

/// The list column on invented demo mail: what its menus and buttons act on, Escape with several
/// rows, account marks, and date labels. Deletes go to a recording fake; nothing reaches Mail.
@MainActor
final class MailListTests: XCTestCase {
    private var deleted: [Int64] = []

    private func demo(accounts: Int = 1, count: Int = 4) -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              setRead: { _, _, _, _ in }, deleteMessage: { [weak self] message, _, _ in
                                  await MainActor.run { self?.deleted.append(message.rowID) }
                              }, draftStore: nil, mailDefaults: nil)
        var boxes = [MailMailbox(rowID: 1, url: "imap://demo/INBOX", unread: 1, total: 2, serverRole: .inbox),
                     MailMailbox(rowID: 2, url: "imap://demo/Trash", unread: 0, total: 0, serverRole: .trash)]
        if accounts > 1 { boxes.append(MailMailbox(rowID: 20, url: "imap://personal/INBOX", unread: 0, total: 1, serverRole: .inbox)) }
        let messages = (1...count).map { index in
            MailSummary(rowID: Int64(index), mailbox: accounts > 1 && index % 2 == 0 ? 20 : 1, subject: "Subject \(index)",
                        senderName: "Ada", senderAddress: "ada@example.com", snippet: "",
                        date: Date().addingTimeInterval(Double(-index * 60)), read: false, flagged: false, conversation: Int64(index))
        }
        model.installDemo(mailboxes: boxes, messages: messages)
        model.serverDrafts = MailServerDraftCoordinator(model: model, save: nil, remove: nil, cleanupStore: nil)
        model.select(1, byUser: false)
        return model
    }

    func testAnActionOnARowOutsideTheSelectionActsOnThatRow() {
        let model = demo()
        model.selectConversationRows([1, 2])
        model.runRowAction(.archive, on: [3], page: nil)
        XCTAssertEqual(model.selectedID, 3)
        XCTAssertEqual(model.selectedConversationRowIDs, [3], "The selection narrows to the clicked row")
        XCTAssertEqual(model.banner, "This account has no Archive mailbox.", "The reader's Archive ran")
    }

    func testDeleteOnSeveralRowsMovesThemAllWithUndo() async {
        let model = demo()
        model.selectConversationRows([1, 2])
        model.runRowAction(.delete, on: [1, 2], page: nil)
        await model.waitForActions()
        XCTAssertEqual(Set(deleted), [1, 2])
        XCTAssertEqual(model.lastChange?.title, "Moved 2 messages to Trash")
    }

    func testDeleteUnderThePointerLeavesTheMessageOnScreen() async {
        let model = demo()
        model.runRowAction(.delete, on: [3], page: nil)
        await model.waitForActions()
        XCTAssertEqual(deleted, [3])
        XCTAssertEqual(model.selectedID, 1)
    }

    func testDeleteAllFromSenderAsksFirst() {
        let model = demo()
        model.runRowAction(.deleteAllFromSender, on: [2], page: nil)
        XCTAssertEqual(model.senderDeleteRequest?.count, 4)
        XCTAssertTrue(deleted.isEmpty, "Nothing moves before you confirm")
    }

    func testEscapeNarrowsSeveralRowsToTheMessageOnScreenThenLeaves() {
        let model = demo()
        let page = MailPage(mail: model)
        model.selectConversationRows([1, 2, 3])
        let focused = model.selectedConversationRowID
        XCTAssertTrue(page.back())
        XCTAssertEqual(model.selectedConversationRowIDs.count, 1)
        XCTAssertEqual(model.selectedConversationRowID, focused)
        XCTAssertFalse(page.back(), "With one row, Escape leaves Mail")
    }

    func testEscapeLeavesTheExpandedMessageBeforeTheSelection() {
        let model = demo()
        let page = MailPage(mail: model)
        model.selectConversationRows([1, 2])
        page.expanded = true
        XCTAssertTrue(page.back())
        XCTAssertFalse(page.expanded)
        XCTAssertEqual(model.selectedConversationRowIDs.count, 2)
    }

    func testTheMenuOffersWhatTheRowsMailboxAllows() {
        let model = demo()
        let one = model.rowMenuContext([1], features: nil)
        XCTAssertEqual(one.roles, [.inbox])
        XCTAssertFalse(one.multiple)
        XCTAssertFalse(one.canSnooze, "Snooze needs a Jevcast account")
        XCTAssertTrue(one.canMove, "Trash is another mailbox of the account")
        XCTAssertTrue(model.rowsHaveUnread([1]))
        XCTAssertFalse(model.rowsAreFlagged([1, 2]))
        XCTAssertTrue(model.rowMenuContext([1, 2], features: nil).multiple)
    }

    func testAccountMarksShowOnlyWhenTheListHoldsSeveralAccounts() {
        let single = demo()
        XCTAssertTrue(single.accountMarks(for: single.conversationGroups).isEmpty)
        let both = demo(accounts: 2)
        XCTAssertEqual(both.accountMarks(for: both.conversationGroups).count, 2)
        // Two accounts on the Mac, but this list holds mail of one: no marks.
        let groups = both.conversationGroups.filter { $0.latest.summary.mailbox == 1 }
        XCTAssertTrue(both.accountMarks(for: groups).isEmpty)
    }

    func testDateLabelsShowInLongListsButNotInOutbox() {
        let model = demo(count: 9)
        let groups = model.conversationGroups
        let now = groups[0].latest.summary.date
        XCTAssertEqual(MailMessageList.sections(groups, place: .inbox, now: now)[groups[0].id], .today)
        XCTAssertTrue(MailMessageList.sections(groups, place: .outbox, now: now).isEmpty)
        XCTAssertTrue(MailMessageList.sections(Array(groups.prefix(5)), place: .inbox, now: now).isEmpty)
    }

    func testKeysAndSelectAllStepOverDateLabels() {
        // Labels are not conversations, so ↓ and Select All see only rows.
        let model = demo(count: 9)
        model.select(1, byUser: true)
        model.moveSelection(1)
        XCTAssertEqual(model.selectedID, 2)
        model.selectAllLoaded()
        XCTAssertEqual(model.selectedConversationRowIDs.count, 9)
    }

    func testChipsApplyAtOnce() {
        let model = demo()
        model.setFilter(MailFilterChip.unread.toggled(model.filter))
        XCTAssertTrue(model.filter.unreadOnly)
        XCTAssertTrue(model.filterIsActive)
        model.clearFilters()
        XCTAssertFalse(model.filterIsActive)
    }

    func testSearchTitleSaysWhatWasFound() {
        XCTAssertEqual(MailSearchSummary.title(count: 0, more: false, loading: true), "Searching…")
        XCTAssertEqual(MailSearchSummary.title(count: 0, more: false, loading: false), "No results")
        XCTAssertEqual(MailSearchSummary.title(count: 1, more: false, loading: false), "1 result")
        XCTAssertEqual(MailSearchSummary.title(count: 12, more: true, loading: false), "12+ results")
    }

    func testRowsRedrawOnlyWhenTheirOwnStateChanges() {
        let model = demo()
        let conversation = model.conversationGroups[0]
        let plain = MailConversationSummaryRow(conversation: conversation, hoverActions: [.archive])
        XCTAssertEqual(plain, MailConversationSummaryRow(conversation: conversation, hoverActions: [.archive], act: { _ in }))
        XCTAssertNotEqual(plain, MailConversationSummaryRow(conversation: conversation, selection: .focused, hoverActions: [.archive]))
        XCTAssertNotEqual(plain, MailConversationSummaryRow(conversation: conversation, hoverActions: [.delete]))
    }

    func testListMetadataIsKeptUntilTheRowsChange() {
        let model = demo(accounts: 2, count: 9)
        let first = model.listMetadata
        let builds = model.listMetadataBuilds
        XCTAssertEqual(first.marks.count, 2)
        XCTAssertFalse(first.sections.isEmpty)
        XCTAssertTrue(first.hoverActions(model.conversationGroups[0].latest.summary).contains(.delete))
        // A redraw, a selection, or typing in a draft does not work it out again.
        _ = model.listMetadata
        model.select(3, byUser: true)
        model.compose()
        model.draft?.body = "Typing"
        _ = model.listMetadata
        XCTAssertEqual(model.listMetadataBuilds, builds, "Nothing the list reads changed")
        // New rows: the labels, marks, and buttons follow them.
        model.messages = Array(model.messages.prefix(3))
        let fewer = model.listMetadata
        XCTAssertEqual(model.listMetadataBuilds, builds + 1)
        XCTAssertTrue(fewer.sections.isEmpty, "A short list has no date labels")
        // A VIP sender marks its rows.
        model.vipAddresses = ["ada@example.com"]
        XCTAssertEqual(model.listMetadata.vip.count, 3)
        XCTAssertEqual(model.listMetadataBuilds, builds + 2)
    }

    func testConversationsAreFoundByRowWithoutASearch() {
        let model = demo(count: 400)
        model.selectAllLoaded()
        XCTAssertEqual(model.selectedConversationRowIDs.count, 400)
        XCTAssertEqual(model.conversation(row: 250)?.latest.summary.rowID, 250)
        XCTAssertEqual(model.conversation(containing: 17)?.latest.summary.rowID, 17)
        XCTAssertNil(model.conversation(row: 9_999))
        XCTAssertTrue(model.rowsHaveUnread(model.selectedConversationRowIDs))
    }

    func testTheSpokenRowSaysWhatTheRowShows() {
        XCTAssertEqual(MailConversationSummaryRow.spokenLabel(sender: "Sam Lee", subject: "Plan", count: 3, date: "25 November 2026 at 12:48",
                                                              unread: true, flagged: true, attachments: true, vip: true, account: "alex@example.com"),
                       "Unread, Sam Lee, VIP, Plan, 3 messages, 25 November 2026 at 12:48, Flagged, Has attachments, Account alex@example.com")
        XCTAssertEqual(MailConversationSummaryRow.spokenLabel(sender: "Sam Lee", subject: "", count: 1, date: "Today", unread: false,
                                                              flagged: false, attachments: false),
                       "Sam Lee, No subject, Today")
    }

    func testSnoozeFromARowMenuShowsThatMessageFirst() async throws {
        let model = demo()
        var account = try XCTUnwrap(NativeMailAccount.preset(.gmail, name: "Ada", email: "ada@example.com"))
        account.id = "demo"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-list-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = MailPage(mail: model, features: MailFeatureCenter(directory: directory, defaults: nil, accounts: [account]))
        model.compose()
        model.draft?.body = "Keep me"
        XCTAssertTrue(page.composing)
        model.runRowAction(.snooze, on: [2], page: page)
        XCTAssertFalse(page.composing, "The reader takes the composer's place, so Snooze has its button")
        XCTAssertNotNil(model.draft, "The draft with text is kept")
        XCTAssertEqual(model.selectedID, 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.snoozeEditorOpen)
    }
}
