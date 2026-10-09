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
