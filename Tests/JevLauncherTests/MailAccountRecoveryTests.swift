import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailAccountRecoveryTests: XCTestCase {
    private var account: NativeMailAccount {
        var value = NativeMailAccount.preset(.gmail, name: "Fixture", email: "fixture@example.com")!
        value.authentication = .oauth
        return value
    }

    func testDuplicateReconnectSharesTheOriginalAttempt() async throws {
        let gate = Gate(), account = account
        let recovery = MailAccountRecovery { _, _ in try await gate.run() }
        recovery.start(account)
        recovery.start(account)
        try await wait { gate.calls == 1 }
        XCTAssertTrue(recovery.working.contains(account.id))
        gate.finish(1)
        try await wait { recovery.working.isEmpty }
        XCTAssertNil(recovery.errors[account.id])
    }

    func testCancelledAttemptCannotOverwriteReplacement() async throws {
        let gate = Gate(), account = account
        let recovery = MailAccountRecovery { _, _ in try await gate.run() }
        recovery.start(account)
        try await wait { gate.calls == 1 }
        recovery.cancel(account.id)
        recovery.start(account)
        try await wait { gate.calls == 2 }
        gate.finish(1, error: MailError.notFound("Old failure"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(recovery.working.contains(account.id))
        XCTAssertNil(recovery.errors[account.id])
        gate.finish(2, error: MailError.notFound("New failure"))
        try await wait { recovery.working.isEmpty }
        XCTAssertEqual(recovery.errors[account.id], "New failure")
    }

    func testFailureKeepsLastSuccessfulSyncAcrossRestart() throws {
        let name = "mail-health-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let account = account, date = Date(timeIntervalSince1970: 1_700_000_000)
        let center = NativeMailCenter(backend: .jevcast, accounts: [account], defaults: defaults)
        center.recordState(account.id, .ready(date))
        center.recordState(account.id, .failed("Expired sign-in", signIn: true))
        XCTAssertEqual(center.lastSuccessfulSync[account.id], date)
        let restarted = NativeMailCenter(backend: .jevcast, accounts: [account], defaults: defaults)
        XCTAssertEqual(restarted.lastSuccessfulSync[account.id], date)
        XCTAssertNil(restarted.states[account.id], "Saved sync time must not imply a current connection")
        restarted.recordState("removed-account", .ready(Date()))
        XCTAssertNil(restarted.lastSuccessfulSync["removed-account"])
    }

    func testAccountWithNoCachedMailboxRemainsVisible() {
        let account = account
        XCTAssertEqual(Set(MailSidebarAccounts.ids(mailboxAccounts: ["cached", "cached"], configured: [account])), ["cached", account.id])
    }

    func testBackFromAccountDetailsPreservesDraftAndBlocksMailKeys() {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false },
                              statusProvider: { .noMail }, draftStore: nil, mailDefaults: nil)
        model.draft = .init(to: "fixture@example.com", subject: "Keep", body: "Keep this draft")
        let page = MailPage(mail: model, accountCenter: NativeMailCenter(backend: .jevcast, defaults: nil))
        page.accountDetailsID = account.id
        XCTAssertFalse(page.composing)
        XCTAssertTrue(page.isTyping)
        XCTAssertFalse(page.handle(.delete))
        XCTAssertEqual(page.backTitle, "Mail")
        XCTAssertTrue(page.back())
        XCTAssertTrue(page.composing)
        XCTAssertEqual(model.draft?.body, "Keep this draft")
    }

    private func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(ready())
    }

    private final class Gate {
        var calls = 0
        private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
        func run() async throws {
            calls += 1
            let id = calls
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        }
        func finish(_ id: Int, error: Error? = nil) {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}
