import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailDeletePresentationTests: XCTestCase {
    func testDeleteThreadSubmitsEveryLoadedReplyAndKeepsOtherThreads() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        var deleted: [Int64] = []
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { message, _, permanent in
                XCTAssertFalse(permanent)
                deleted.append(message.rowID)
            }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: fixture.mailboxes, messages: fixture.messages)
        model.select(100, byUser: true)
        model.delete()
        XCTAssertTrue(Set(model.messages.map(\.rowID)).isDisjoint(with: [100, 101, 102, 103]))
        await model.waitForActions()
        XCTAssertEqual(Set(deleted), [100, 101, 102, 103])
        XCTAssertEqual(deleted.count, 4)
        XCTAssertTrue(model.messages.contains { $0.rowID == 2 })
        model.install(fixture.messages)
        XCTAssertTrue(Set(model.messages.map(\.rowID)).isDisjoint(with: deleted), "A stale refresh must not reinsert a completed removal.")
    }

    func testDeleteOffersUndoWithTheMessagesThatMoved() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { _, _, _ in }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: fixture.mailboxes, messages: fixture.messages)
        model.delete(2)
        let change = try XCTUnwrap(model.lastChange)
        XCTAssertEqual(change.title, "Moved to Trash"); XCTAssertEqual(change.operation, .trash)
        XCTAssertTrue(change.moved.isEmpty, "A message counts as moved only after the server took the change.")
        await model.waitForActions()
        XCTAssertEqual(model.lastChange?.moved.map(\.message.rowID), [2])
        XCTAssertNil(model.banner, "The Undo note shows; no other note covers it.")
        // A conversation moves every loaded reply, and Undo holds all of them.
        model.delete(100)
        XCTAssertEqual(model.lastChange?.title, "Moved 4 messages to Trash")
        await model.waitForActions()
        XCTAssertEqual(Set(model.lastChange?.moved.map(\.message.rowID) ?? []), [100, 101, 102, 103])
    }

    func testDeleteAllFromASenderAsksWithTheCountFirst() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        var deleted: [Int64] = []
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { message, _, permanent in
                XCTAssertFalse(permanent)
                deleted.append(message.rowID)
            }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: fixture.mailboxes, messages: fixture.messages)
        // The mail index as it is now, read again at the moment of the move.
        model.readRows = { ids in fixture.messages.filter { ids.contains($0.rowID) } }
        model.select(100, byUser: true)
        model.deleteAllFromSender()
        let request = try XCTUnwrap(model.senderDeleteRequest, "Nothing moves before you confirm")
        XCTAssertEqual(request.sender, "Sam Lee")
        XCTAssertEqual(request.address, "sam@example.com")
        XCTAssertEqual(Set(request.rowIDs), [100, 102])
        XCTAssertEqual(request.noun, "2 messages")
        XCTAssertNil(model.lastChange)
        await model.waitForActions()
        XCTAssertTrue(deleted.isEmpty)

        // Cancel moves nothing.
        model.senderDeleteRequest = nil
        model.confirmDeleteAllFromSender()
        XCTAssertTrue(model.messages.contains { $0.rowID == 100 })

        model.deleteAllFromSender()
        await model.confirmDeleteAllFromSender()?.value
        XCTAssertNil(model.senderDeleteRequest)
        XCTAssertEqual(model.lastChange?.title, "Moved 2 messages from Sam Lee to Trash", "The Undo note says what happened")
        XCTAssertNil(model.banner, "No other note covers the Undo note")
        await model.waitForActions()
        XCTAssertEqual(Set(deleted), [100, 102])
        XCTAssertEqual(Set(model.lastChange?.moved.map(\.message.rowID) ?? []), [100, 102])
        XCTAssertTrue(model.messages.contains { $0.rowID == 101 }, "Other senders' messages stay")
    }

    func testDeleteAllFromASenderInTrashIsRefused() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        let trash = try XCTUnwrap(fixture.mailboxes.first { $0.role == .trash })
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { _, _, _ in XCTFail("Nothing is deleted") }, draftStore: nil, mailDefaults: nil)
        let inTrash = fixture.messages.map { original -> MailSummary in var message = original; message.mailbox = trash.rowID; return message }
        model.installDemo(mailboxes: fixture.mailboxes, messages: inTrash)
        model.select(100, byUser: true)
        model.deleteAllFromSender()
        XCTAssertNil(model.senderDeleteRequest)
        XCTAssertNotNil(model.banner)
    }

    func testTheUndoNoteWaitsWhileThePointerIsOnIt() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { _, _, _ in }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: fixture.mailboxes, messages: fixture.messages)
        model.undoSeconds = 0.3
        model.delete(2)
        model.hoverUndo(true)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNotNil(model.lastChange, "The note stays while the pointer is on it")
        model.hoverUndo(false)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotNil(model.lastChange, "At least three more seconds after the pointer leaves")

        model.delete(3)
        let second = try XCTUnwrap(model.lastChange?.id)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNotEqual(model.lastChange?.id, second, "Without the pointer, the note goes after its time")
    }

    func testUndoCountdownPausesAndLeavesTimeAfterTheHover() {
        let start = Date(timeIntervalSince1970: 1_000)
        var countdown = MailUndoCountdown(start: start)
        XCTAssertFalse(countdown.expired(at: start.addingTimeInterval(7.9)))
        XCTAssertTrue(countdown.expired(at: start.addingTimeInterval(8)))

        countdown = MailUndoCountdown(start: start)
        countdown.hover(true, at: start.addingTimeInterval(7))
        XCTAssertFalse(countdown.expired(at: start.addingTimeInterval(60)), "Never while hovering")
        countdown.hover(false, at: start.addingTimeInterval(60))
        XCTAssertFalse(countdown.expired(at: start.addingTimeInterval(62.9)))
        XCTAssertTrue(countdown.expired(at: start.addingTimeInterval(63)))

        countdown = MailUndoCountdown(start: start)
        countdown.hover(true, at: start.addingTimeInterval(1))
        countdown.hover(false, at: start.addingTimeInterval(2))
        XCTAssertFalse(countdown.expired(at: start.addingTimeInterval(8.9)), "A short hover gives back the time it had: 7 seconds")
        XCTAssertTrue(countdown.expired(at: start.addingTimeInterval(9)))

        // On the note 1 s in, off 10 s later: the 7 s it had come back, not the 3 s minimum.
        countdown = MailUndoCountdown(start: start)
        countdown.hover(true, at: start.addingTimeInterval(1))
        countdown.hover(false, at: start.addingTimeInterval(11))
        XCTAssertFalse(countdown.expired(at: start.addingTimeInterval(17.9)), "Hovering never eats the time")
        XCTAssertTrue(countdown.expired(at: start.addingTimeInterval(18)))
    }

    func testAFailedDeleteOffersNoUndo() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { _, _, _ in throw LauncherError("Server refused the move") }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: fixture.mailboxes, messages: fixture.messages)
        model.delete(2)
        XCTAssertNotNil(model.lastChange)
        await model.waitForActions()
        XCTAssertNil(model.lastChange, "Nothing moved, so there is nothing to undo.")
        XCTAssertTrue(model.banner?.contains("Server refused the move") == true)
    }

    func testFailedDeleteReturnsOnRefreshAndReportsServerFailure() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { _, _, _ in throw LauncherError("Server refused the move") }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: fixture.mailboxes, messages: fixture.messages)
        model.delete(2)
        await model.waitForActions()
        XCTAssertTrue(model.banner?.contains("Server refused the move") == true)
        model.install(fixture.messages)
        XCTAssertTrue(model.messages.contains { $0.rowID == 2 }, "A failed server action must not be hidden as a successful deletion.")
    }

    func testPartialThreadFailureRestoresOnlyTheRejectedReply() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        var submitted: [Int64] = []
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { message, _, _ in
                submitted.append(message.rowID)
                if message.rowID == 102 { throw LauncherError("Server refused one reply") }
            }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: fixture.mailboxes, messages: fixture.messages)
        model.delete(100)
        await model.waitForActions()
        model.install(fixture.messages)
        XCTAssertEqual(Set(submitted), [100, 101, 102, 103])
        XCTAssertEqual(Set(model.messages.filter { $0.conversation == 900 }.map(\.rowID)), [102])
        XCTAssertTrue(model.banner?.contains("Server refused one reply") == true)
    }

    func testDeleteInTrashTargetsOnlySelectedReply() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        let trash = try XCTUnwrap(fixture.mailboxes.first { $0.role == .trash })
        var deleted: [Int64] = []
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { message, _, _ in deleted.append(message.rowID) }, draftStore: nil, mailDefaults: nil)
        let replies = fixture.messages.filter { $0.conversation == 900 }.map { original in
            var message = original
            message.mailbox = trash.rowID
            return message
        }
        model.installDemo(mailboxes: fixture.mailboxes, messages: replies)
        model.select(102, byUser: true)
        model.delete()
        await model.waitForActions()
        XCTAssertEqual(deleted, [102])
        XCTAssertEqual(Set(model.messages.map(\.rowID)), [100, 101, 103])
    }

    func testStaleRowDeleteDoesNotDeleteCurrentSelection() async throws {
        let fixture = try XCTUnwrap(MailSnapshots.thread().mail)
        var calls = 0
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
            deleteMessage: { _, _, _ in calls += 1 }, draftStore: nil, mailDefaults: nil)
        model.installDemo(mailboxes: fixture.mailboxes, messages: fixture.messages)
        let before = model.messages
        model.delete(-999)
        await model.waitForActions()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.messages, before)
    }
}
