import Foundation
import LauncherCore
import XCTest
@testable import JevLauncher

@MainActor
final class MailSnoozeScheduleTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mail-delay-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var account: MailAccountIdentity { .init(accountID: "fixture", address: "me@example.com") }
    private var now: Date { Date(timeIntervalSince1970: 2_000_000) }

    private func message() -> MailSummary {
        MailSummary(rowID: 9, mailbox: 2, subject: "Plans", senderName: "Sam", senderAddress: "sam@example.com",
                    snippet: "See you soon", date: now, read: false, flagged: false, conversation: 4,
                    messageKey: "provider-message-9")
    }

    private func draft(body: String = "Later") -> MailModel.Draft {
        MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: account.accountID,
                        fromAddress: account.address, mode: .new, to: "sam@example.com", subject: "Plans", body: body)
    }

    private func appleDraft() -> MailModel.Draft {
        var value = draft()
        value.backend = MailBackend.appleMail.rawValue
        return value
    }

    func testSnoozeReturnsAtDueTimeAndCancelIsDurable() async throws {
        let clock = MailManualClock(now: now)
        let center = MailSnoozeCenter(store: MailSnoozeStore(directory: directory), clock: clock)
        let item = try center.snooze(message: message(), account: account, until: now.addingTimeInterval(60))
        center.start()
        clock.advance(by: 60)
        for _ in 0..<20 where center.ready.isEmpty { await Task.yield() }
        XCTAssertEqual(center.ready.map(\.identity), [item.identity])
        _ = try center.consumeReady(item.identity)
        XCTAssertTrue(center.entries.isEmpty)

        let second = try center.snooze(message: message(), account: account, messageID: "second", until: now.addingTimeInterval(120))
        try center.cancel(second.identity)
        XCTAssertTrue(try MailSnoozeStore(directory: directory).load().entries.isEmpty)
        center.stop()
    }

    func testRelaunchConvertsMissedSnoozeToReviewWithoutReturningIt() throws {
        let store = MailSnoozeStore(directory: directory)
        let due = MailSnoozeEntry(identity: .init(account: account, messageKey: message().messageKey), account: account,
                                  summary: message(), createdAt: now.addingTimeInterval(-120), scheduledAt: now.addingTimeInterval(-1),
                                  state: .scheduled, note: nil)
        try store.save(.init(entries: [due]))
        let center = MailSnoozeCenter(store: store, clock: MailManualClock(now: now))
        XCTAssertEqual(center.needsReview.count, 1)
        XCTAssertTrue(center.ready.isEmpty)
    }

    func testStartingSnoozeAfterDueReturnsItInsteadOfReclassifyingIt() async throws {
        let clock = MailManualClock(now: now)
        let center = MailSnoozeCenter(store: MailSnoozeStore(directory: directory), clock: clock)
        _ = try center.snooze(message: message(), account: account, until: now.addingTimeInterval(60))
        clock.advance(by: 60)
        center.start()
        for _ in 0..<20 where center.ready.isEmpty { await Task.yield() }
        XCTAssertEqual(center.ready.count, 1)
        center.stop()
    }

    func testAccountDisconnectMarksSnoozeForReviewInsteadOfDeletingIt() throws {
        let clock = MailManualClock(now: now)
        let center = MailSnoozeCenter(store: MailSnoozeStore(directory: directory), clock: clock)
        let item = try center.snooze(message: message(), account: account, until: now.addingTimeInterval(60))
        try center.reconcile(accounts: [])
        XCTAssertEqual(center.needsReview.map(\.identity), [item.identity])
        XCTAssertEqual(try MailSnoozeStore(directory: directory).load().entries.count, 1)
    }

    func testSchedulePersistsCompleteDraftAndFailedSubmissionNeedsReview() async throws {
        let clock = MailManualClock(now: now)
        var attempts = 0
        let center = MailScheduleCenter(store: MailScheduleStore(directory: directory), clock: clock,
                                        submission: { _ in
                                            attempts += 1
                                            throw LauncherError("Network is unavailable.")
                                        }, lateTolerance: 10)
        var scheduledDraft = draft()
        scheduledDraft.attachments = [.init(filename: "note.txt", mimeType: "text/plain", data: Data("bytes".utf8))]
        let item = try center.schedule(scheduledDraft, account: account, at: now.addingTimeInterval(60))
        let persisted = try MailScheduleStore(directory: directory).load().entries.first
        XCTAssertEqual(persisted?.draft, scheduledDraft)
        XCTAssertEqual(persisted?.draft.source, scheduledDraft.source)

        center.start()
        clock.advance(by: 60)
        await Task.yield()
        await center.dispatchNow(item.id)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(center.needsReview.first?.id, item.id)
        center.stop()
    }

    func testScheduleDispatchCheckpointAllowsAtMostOneSendAcrossRace() async throws {
        let clock = MailManualClock(now: now)
        var attempts = 0
        let gate = DispatchGate()
        let center = MailScheduleCenter(store: MailScheduleStore(directory: directory), clock: clock,
                                        submission: { _ in
                                            attempts += 1
                                            await gate.wait()
                                            return .serverAccepted(nil)
                                        }, lateTolerance: 10)
        let item = try center.schedule(draft(), account: account, at: now.addingTimeInterval(60))
        clock.advance(by: 60)
        let first = Task { await center.dispatchNow(item.id) }
        await Task.yield()
        let second = Task { await center.dispatchNow(item.id) }
        await Task.yield()
        XCTAssertEqual(try MailScheduleStore(directory: directory).load().entries.first?.state, .dispatching)
        gate.open()
        await first.value
        await second.value
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(center.submitted.first?.id, item.id)
    }

    func testStartingScheduleAfterDueStillDispatchesWithinTolerance() async throws {
        let clock = MailManualClock(now: now)
        var attempts = 0
        let center = MailScheduleCenter(store: MailScheduleStore(directory: directory), clock: clock,
                                        submission: { _ in
                                            attempts += 1
                                            return .serverAccepted(nil)
                                        }, lateTolerance: 10)
        let item = try center.schedule(draft(), account: account, at: now.addingTimeInterval(60))
        clock.advance(by: 60)
        center.start()
        for _ in 0..<20 where center.submitted.isEmpty { await Task.yield() }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(center.submitted.map(\.id), [item.id])
        center.stop()
    }

    func testTimerRestartWaitsForActiveHandoffAndShutdownAwaitsIt() async throws {
        let clock = MailManualClock(now: now)
        let gate = DispatchGate()
        var attempts = 0
        let center = MailScheduleCenter(store: MailScheduleStore(directory: directory), clock: clock,
                                        submission: { _ in
                                            attempts += 1
                                            if attempts == 1 { await gate.wait() }
                                            return .serverAccepted(nil)
                                        }, lateTolerance: 10)
        let first = try center.schedule(draft(body: "first"), account: account, at: now.addingTimeInterval(60))
        let second = try center.schedule(draft(body: "second"), account: account, at: now.addingTimeInterval(61))
        center.start()
        clock.advance(by: 60)
        for _ in 0..<20 {
            if (try? MailScheduleStore(directory: directory).load().entries.first?.state) == .dispatching { break }
            await Task.yield()
        }
        XCTAssertEqual(try MailScheduleStore(directory: directory).load().entries.first?.state, .dispatching)

        // Editing the second item restarts the timer while the first handoff is still active.
        _ = try center.edit(second.id, draft: second.draft, account: account,
                            at: now.addingTimeInterval(61))
        clock.advance(by: 1)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(attempts, 1)
        XCTAssertLessThan(clock.sleepCount, 20, "A handoff must not make the timer hot-loop.")

        let firstDispatch = Task { await center.dispatchNow(first.id) }
        let completion = CompletionFlag()
        let waiter = Task {
            await center.waitForDispatches()
            await completion.set()
        }
        for _ in 0..<5 { await Task.yield() }
        let beforeCompletion = await completion.value
        XCTAssertFalse(beforeCompletion)
        gate.open()
        await firstDispatch.value
        _ = await waiter.value
        for _ in 0..<20 where center.submitted.count < 2 { await Task.yield() }
        let afterCompletion = await completion.value
        XCTAssertTrue(afterCompletion)
        XCTAssertEqual(attempts, 2)
        center.stop()
    }

    func testRestartOfInFlightScheduleNeedsReviewWithoutAutomaticResend() throws {
        let store = MailScheduleStore(directory: directory)
        let item = MailScheduleEntry(id: UUID(), account: account, draft: draft(), createdAt: now.addingTimeInterval(-60),
                                     scheduledAt: now.addingTimeInterval(-1), state: .dispatching,
                                     note: "Sending…", lastAttemptAt: now.addingTimeInterval(-1))
        try store.save(.init(entries: [item]))
        var attempts = 0
        let center = MailScheduleCenter(store: store, clock: MailManualClock(now: now), submission: { _ in
            attempts += 1
            return .serverAccepted(nil)
        })
        XCTAssertEqual(center.needsReview.first?.id, item.id)
        XCTAssertEqual(attempts, 0)
    }

    func testScheduleCancelAndAccountChangeKeepReviewableSnapshot() throws {
        let clock = MailManualClock(now: now)
        let store = MailScheduleStore(directory: directory)
        let center = MailScheduleCenter(store: store, clock: clock)
        let item = try center.schedule(draft(), account: account, at: now.addingTimeInterval(60))
        try center.reconcile(accounts: [.init(accountID: account.accountID, address: "changed@example.com")])
        XCTAssertEqual(center.needsReview.first?.id, item.id)
        XCTAssertEqual(try store.load().entries.first?.draft.body, "Later")
        try center.cancel(item.id)
        XCTAssertEqual(center.visible.count, 0)
    }

    func testScheduleRequiresNativeBackend() throws {
        let center = MailScheduleCenter(store: MailScheduleStore(directory: directory), clock: MailManualClock(now: now))
        XCTAssertThrowsError(try center.schedule(appleDraft(), account: account, at: now.addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? MailScheduleError,
                           .invalidDraft("Scheduled sending is available only for Jevcast accounts."))
        }
    }

    func testUncertainScheduleRequiresExplicitSentCheck() throws {
        var uncertain = draft()
        uncertain.uncertainSend = true
        let center = MailScheduleCenter(store: MailScheduleStore(directory: directory), clock: MailManualClock(now: now))
        XCTAssertThrowsError(try center.schedule(uncertain, account: account, at: now.addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? MailScheduleError, .sentCheckRequired)
        }
        let item = try center.schedule(uncertain, account: account, at: now.addingTimeInterval(60), confirmSentCheck: true)
        XCTAssertEqual(item.state, .scheduled)
        XCTAssertFalse(item.draft.uncertainSend)
    }

    func testDispatchReviewCannotBeRescheduledWithoutSentCheck() throws {
        let store = MailScheduleStore(directory: directory)
        let item = MailScheduleEntry(id: UUID(), account: account, draft: draft(), createdAt: now.addingTimeInterval(-60),
                                     scheduledAt: now.addingTimeInterval(60), state: .needsReview,
                                     note: "Check Sent before resending.", lastAttemptAt: now.addingTimeInterval(-1))
        try store.save(.init(entries: [item]))
        let center = MailScheduleCenter(store: store, clock: MailManualClock(now: now))
        XCTAssertThrowsError(try center.edit(item.id, draft: item.draft, account: account,
                                             at: now.addingTimeInterval(120))) { error in
            XCTAssertEqual(error as? MailScheduleError, .sentCheckRequired)
        }
        _ = try center.edit(item.id, draft: item.draft, account: account,
                            at: now.addingTimeInterval(120), confirmSentCheck: true)
        XCTAssertEqual(center.scheduled.first?.id, item.id)
    }

    func testSchedulePersistenceFailureStopsTimerAndKeepsCorruptBytes() async throws {
        let clock = MailManualClock(now: now)
        let store = MailScheduleStore(directory: directory)
        let center = MailScheduleCenter(store: store, clock: clock,
                                        submission: { _ in XCTFail("A corrupt store must not reach transport"); return .serverAccepted(nil) },
                                        lateTolerance: 10)
        let item = try center.schedule(draft(), account: account, at: now.addingTimeInterval(60))
        let file = directory.appendingPathComponent("schedules.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: file)
        center.start()
        clock.advance(by: 60)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(center.scheduled.first?.id, item.id)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(center.persistenceProblem)
        center.start() // Persistence remains blocked. This must not create a retry loop.
        clock.advance(by: 60)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        center.stop()
    }

    func testSnoozePersistenceFailureStopsTimerAndKeepsCorruptBytes() async throws {
        let clock = MailManualClock(now: now)
        let store = MailSnoozeStore(directory: directory)
        let center = MailSnoozeCenter(store: store, clock: clock)
        let item = try center.snooze(message: message(), account: account, until: now.addingTimeInterval(60))
        let file = directory.appendingPathComponent("snoozes.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: file)
        center.start()
        clock.advance(by: 60)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(center.snoozed.first?.identity, item.identity)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(center.persistenceProblem)
        center.start() // Persistence remains blocked. This must not create a retry loop.
        clock.advance(by: 60)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        center.stop()
    }

    func testCorruptDelayStoreIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("schedules.json")
        let bytes = Data("{bad".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try MailScheduleStore(directory: directory).save(.init()))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}

private final class DispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        let immediate = lock.withLock { opened }
        if immediate { return }
        await withCheckedContinuation { continuation in
            let release = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if release { continuation.resume() }
        }
    }

    func open() {
        let continuations = lock.withLock { opened = true; let current = waiters; waiters.removeAll(); return current }
        continuations.forEach { $0.resume() }
    }
}

private actor CompletionFlag {
    private var finished = false

    func set() { finished = true }
    var value: Bool { finished }
}
