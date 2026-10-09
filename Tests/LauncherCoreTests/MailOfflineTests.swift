import XCTest
@testable import LauncherCore

final class MailOfflineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jevmail-offline-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mailbox(_ store: NativeMailStore) async throws -> NativeMailStore.Mailbox {
        let entries = [IMAPListEntry(flags: ["\\Inbox"], delimiter: "/", rawName: "INBOX"),
                       IMAPListEntry(flags: [], delimiter: "/", rawName: "Archive")]
        let boxes = try await store.replaceMailboxes(account: "offline-account", with: entries)
        var inbox = try XCTUnwrap(boxes.first { $0.name == "INBOX" })
        inbox.uidValidity = 42
        inbox.uidNext = 20
        try await store.saveSyncState(inbox)
        let current = try await store.mailbox(inbox.rowID)
        return try XCTUnwrap(current)
    }

    func testBodyPolicyCanUpgradeIndexedTextToRawAndRawToIndex() async throws {
        let store = try NativeMailStore(root: root)
        let box = try await mailbox(store)
        var message = SyncedMessage(uid: 7, date: Date())
        message.subject = "Upgrade"; message.senderAddress = "sender@example.com"
        try await store.upsert([message], into: box.rowID)
        let storedID = try await store.rowID(uid: 7, in: box.rowID)
        let rowID = try XCTUnwrap(storedID)
        let raw = Data("Subject: Upgrade\r\n\r\nFull body".utf8)
        try await store.saveIndexedBodyText(rowID, text: "Full body")
        let needsRaw = try await store.missingBodies(in: box.rowID, limit: 10, maxSize: .max, requireRaw: true)
        XCTAssertEqual(needsRaw.map(\.rowID), [rowID])
        try await store.clearOfflineCache(accountID: "offline-account")
        try await store.saveBody(rowID, raw: raw, indexText: false)
        let needsIndex = try await store.missingBodies(in: box.rowID, limit: 10, maxSize: .max, requireRaw: false, requireIndex: true)
        XCTAssertEqual(needsIndex.map(\.rowID), [rowID])
        try await store.saveIndexedBodyText(rowID, text: "Full body")
        let hasBody = try await store.hasBody(rowID)
        XCTAssertTrue(hasBody)
        let done = try await store.missingBodies(in: box.rowID, limit: 10, maxSize: .max, requireRaw: true, requireIndex: true)
        XCTAssertTrue(done.isEmpty)
    }

    func testPolicyAndQueueSurviveStoreRestart() async throws {
        let store = try NativeMailStore(root: root)
        _ = try await mailbox(store)
        let policy = MailOfflinePolicy(mode: .selectedFolders, recentMessageLimit: 125,
                                       selectedFolderNames: ["INBOX"], downloadAttachments: true,
                                       indexBodies: true, paused: true)
        try await store.saveOfflinePolicy(policy, for: "offline-account")
        let action = MailOfflineAction(accountID: "offline-account", kind: .read, mailboxName: "INBOX",
                                       uidValidity: 42, uid: 7, messageID: "<seven@example.com>", desiredValue: true)
        _ = try await store.enqueueOfflineAction(action)

        let restarted = try NativeMailStore(root: root)
        let restoredPolicy = try await restarted.offlinePolicy(for: "offline-account")
        let restoredActions = try await restarted.offlineActions(accountID: "offline-account")
        XCTAssertEqual(restoredPolicy, policy)
        XCTAssertEqual(restoredActions, [action])
    }

    func testFullBodyTextIsSearchableBeyondPreviewAndCacheClearKeepsQueue() async throws {
        let store = try NativeMailStore(root: root)
        let box = try await mailbox(store)
        var message = SyncedMessage(uid: 7, date: Date(timeIntervalSince1970: 1_800_000_000))
        message.subject = "Long body"; message.senderAddress = "sender@example.com"; message.messageID = "<seven@example.com>"
        try await store.upsert([message], into: box.rowID)
        let storedRowID = try await store.rowID(uid: 7, in: box.rowID)
        let rowID = try XCTUnwrap(storedRowID)
        let prefix = String(repeating: "ordinary ", count: 600)
        let raw = Data("From: sender@example.com\r\nSubject: Long body\r\nMessage-ID: <seven@example.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(prefix)needleattheend\r\n".utf8)
        try await store.saveBody(rowID, raw: raw)
        let found = try await store.searchIndexed(mailboxIDs: [box.rowID], text: "needleattheend")
        XCTAssertEqual(found, [rowID])

        let action = MailOfflineAction(accountID: "offline-account", kind: .flag, mailboxName: "INBOX",
                                       uidValidity: 42, uid: 7, messageID: "<seven@example.com>", desiredValue: true)
        _ = try await store.enqueueOfflineAction(action)
        try await store.clearOfflineCache(accountID: "offline-account")
        let queued = try await store.offlineActions(accountID: "offline-account")
        let hasBody = try await store.hasBody(rowID)
        let missing = try await store.searchIndexed(mailboxIDs: [box.rowID], text: "needleattheend")
        XCTAssertEqual(queued, [action])
        XCTAssertFalse(hasBody)
        XCTAssertEqual(missing, [])
    }

    func testCoverageDoesNotClaimCompleteWhenServerCountIsUnknown() async throws {
        let store = try NativeMailStore(root: root)
        let box = try await mailbox(store)
        var message = SyncedMessage(uid: 7, date: Date())
        message.subject = "Cached"; message.senderAddress = "sender@example.com"
        try await store.upsert([message], into: box.rowID)
        let coverage = try await store.offlineCoverage(accountID: "offline-account")
        let inbox = try XCTUnwrap(coverage.first { $0.name == "INBOX" })
        XCTAssertNil(inbox.coverage)
        XCTAssertFalse(inbox.completeHistory)
        XCTAssertEqual(inbox.downloadedHeaders, 1)
    }

    func testAllHistoryBodyQueryReachesPastTheFormerFiveThousandWindow() async throws {
        let store = try NativeMailStore(root: root)
        let box = try await mailbox(store)
        let messages = (1...6_001).map { uid -> SyncedMessage in
            var message = SyncedMessage(uid: UInt32(uid), date: Date(timeIntervalSince1970: TimeInterval(uid)))
            message.subject = "Message \(uid)"
            message.senderAddress = "sender@example.com"
            // Make the newest 5,000 ineligible so a fixed newest-window query would return none.
            message.size = uid > 1_001 ? 2_000_000 : 0
            return message
        }
        try await store.upsert(messages, into: box.rowID)

        let rows = try await store.missingBodies(in: box.rowID, within: nil, limit: 1, maxSize: 1_000_000)
        XCTAssertEqual(rows.first?.uid, 1_001)
    }

    func testRecentPolicyUsesItsLimitAndBodyToggles() async throws {
        let server = FakeIMAPServer(mailboxes: [("INBOX", [])])
        for index in 1...4 { server.deliver(to: "INBOX", subject: "Recent \(index)", body: "Body \(index)") }
        let account = NativeMailAccount(id: "offline-account", provider: .yahoo, name: "Offline", email: "offline@example.com",
                                        imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
                                        smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls))
        let store = try NativeMailStore(root: root)
        var syncPolicy = MailSyncPolicy()
        syncPolicy.firstInbox = 20
        syncPolicy.firstOther = 0
        syncPolicy.prefetchInbox = 0
        syncPolicy.bodyBatch = 2
        let sync = MailAccountSync(account: account, store: store, policy: syncPolicy,
                                   credential: { .password("app-password") }, transport: server.factory)
        try await store.saveOfflinePolicy(MailOfflinePolicy(mode: .recent, recentMessageLimit: 2,
                                                            downloadAttachments: false, indexBodies: true), for: account.id)
        guard case .done = await sync.pass(.everything) else { return XCTFail("fixture sync did not finish") }
        let firstCoverage = try await store.offlineCoverage(accountID: account.id)
        let first = firstCoverage.first { $0.name == "INBOX" }
        XCTAssertEqual(first?.downloadedHeaders, 2)
        XCTAssertEqual(first?.indexedBodies, 2)

        try await store.clearOfflineCache(accountID: account.id)
        try await store.saveOfflinePolicy(MailOfflinePolicy(mode: .recent, recentMessageLimit: 2,
                                                            downloadAttachments: false, indexBodies: false), for: account.id)
        guard case .done = await sync.pass(.everything) else { return XCTFail("fixture toggle pass did not finish") }
        let disabledCoverage = try await store.offlineCoverage(accountID: account.id)
        let disabled = disabledCoverage.first { $0.name == "INBOX" }
        XCTAssertEqual(disabled?.indexedBodies, 0)
        await sync.stop()
    }

    func testIdentityMismatchCanBeHeldForReviewWithoutRetry() async throws {
        let store = try NativeMailStore(root: root)
        _ = try await mailbox(store)
        var action = MailOfflineAction(accountID: "offline-account", kind: .move, mailboxName: "INBOX",
                                       uidValidity: 99, uid: 7, destinationMailboxName: "Archive", destinationUIDValidity: 42)
        action.state = .review; action.lastError = "The server changed INBOX's identity."
        _ = try await store.enqueueOfflineAction(action)
        let status = try await store.offlineQueueStatus(accountID: "offline-account")
        XCTAssertEqual(status.pending, 0); XCTAssertEqual(status.review, 1)
        let reviewedActions = try await store.offlineActions(accountID: "offline-account")
        let reviewed = reviewedActions.first?.lastError
        XCTAssertEqual(reviewed, action.lastError)
    }

    func testPendingReadReplaysWithFakeServerAndStaleMoveStopsForReview() async throws {
        let server = FakeIMAPServer()
        let account = NativeMailAccount(id: "offline-account", provider: .yahoo, name: "Offline", email: "offline@example.com",
                                        imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
                                        smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls))
        let uid = server.deliver(to: "INBOX", subject: "Queued", messageID: "<queued@example.com>")
        let store = try NativeMailStore(root: root)
        let sync = MailAccountSync(account: account, store: store, credential: { .password("app-password") },
                                    transport: { _, _, _ in server.connect() })
        guard case .done = await sync.pass(.everything) else { return XCTFail("fixture sync did not finish") }
        let boxes = await sync.mailboxes
        let inbox = try XCTUnwrap(boxes.first { $0.name == "INBOX" })
        let storedRowID = try await store.rowID(uid: uid, in: inbox.rowID)
        let rowID = try XCTUnwrap(storedRowID)
        let read = MailOfflineAction(accountID: account.id, kind: .read, mailboxName: inbox.name,
                                     uidValidity: try XCTUnwrap(inbox.uidValidity), uid: uid,
                                     messageID: "<queued@example.com>", desiredValue: true)
        _ = try await store.enqueueOfflineAction(read)
        await sync.replayOfflineActions()
        XCTAssertTrue(server.mailbox("INBOX")?.messages.first { $0.uid == uid }?.flags.contains("\\Seen") == true)
        let replayed = try await store.offlineActions(accountID: account.id)
        XCTAssertTrue(replayed.isEmpty)
        XCTAssertGreaterThan(rowID, 0)

        let move = MailOfflineAction(accountID: account.id, kind: .move, mailboxName: inbox.name,
                                     uidValidity: try XCTUnwrap(inbox.uidValidity), uid: uid,
                                     destinationMailboxName: "Archive", destinationUIDValidity: nil)
        _ = try await store.enqueueOfflineAction(move)
        server.mailbox("INBOX")?.uidValidity = 9_999
        await sync.replayOfflineActions()
        let heldActions = try await store.offlineActions(accountID: account.id)
        let held = heldActions.first
        XCTAssertEqual(held?.state, .review)
        await sync.stop()
    }

    func testMoveReplayPersistsReviewBeforeAnUncertainNetworkStep() async throws {
        let server = FakeIMAPServer(mailboxes: [("INBOX", []), ("Archive", ["\\Archive"])])
        let account = NativeMailAccount(id: "offline-account", provider: .yahoo, name: "Offline", email: "offline@example.com",
                                        imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
                                        smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls))
        let switcher = MoveFailureSwitch()
        let store = try NativeMailStore(root: root)
        let sync = MailAccountSync(account: account, store: store, credential: { .password("app-password") },
                                   transport: { _, _, _ in MoveFailureTransport(base: server.connect(), switcher: switcher) })
        let uid = server.deliver(to: "INBOX", subject: "Move me", messageID: "<move@example.com>")
        guard case .done = await sync.pass(.everything) else { return XCTFail("fixture sync did not finish") }
        let boxes = await sync.mailboxes
        let inbox = try XCTUnwrap(boxes.first { $0.name == "INBOX" })
        let archive = try XCTUnwrap(boxes.first { $0.name == "Archive" })
        let action = MailOfflineAction(accountID: account.id, kind: .move, mailboxName: inbox.name,
                                       uidValidity: try XCTUnwrap(inbox.uidValidity), uid: uid,
                                       messageID: "<move@example.com>", destinationMailboxName: archive.name,
                                       destinationUIDValidity: archive.uidValidity)
        _ = try await store.enqueueOfflineAction(action)

        switcher.failMove = true
        await sync.replayOfflineActions()
        let queued = try await store.offlineActions(accountID: account.id)
        let held = try XCTUnwrap(queued.first)
        XCTAssertEqual(held.state, .review)
        XCTAssertEqual(held.attempts, 1)
        XCTAssertTrue(server.mailbox("INBOX")?.messages.contains { $0.uid == uid } == true)
        await sync.stop()
    }

    func testReadValidationKeepsTransientFailuresPendingButStopsOnAuthFailure() async throws {
        let server = FakeIMAPServer(mailboxes: [("INBOX", [])])
        let account = NativeMailAccount(id: "offline-account", provider: .yahoo, name: "Offline", email: "offline@example.com",
                                        imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
                                        smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls))
        let credentials = CredentialFailureSwitch()
        let store = try NativeMailStore(root: root)
        let sync = MailAccountSync(account: account, store: store, credential: { try credentials.read() },
                                   transport: server.factory)
        let uid = server.deliver(to: "INBOX", subject: "Read me", messageID: "<read@example.com>")
        guard case .done = await sync.pass(.everything) else { return XCTFail("fixture sync did not finish") }
        let syncedMailboxes = await sync.mailboxes
        let inbox = try XCTUnwrap(syncedMailboxes.first { $0.name == "INBOX" })
        let action = MailOfflineAction(accountID: account.id, kind: .read, mailboxName: inbox.name,
                                       uidValidity: try XCTUnwrap(inbox.uidValidity), uid: uid,
                                       messageID: "<read@example.com>", desiredValue: true)
        _ = try await store.enqueueOfflineAction(action)

        credentials.failure = MailTransportError.closed
        await sync.replayOfflineActions()
        var queued = try await store.offlineActions(accountID: account.id)
        XCTAssertEqual(queued.first?.state, .pending)

        credentials.failure = MailError.signInFailed("expired")
        await sync.replayOfflineActions()
        queued = try await store.offlineActions(accountID: account.id)
        XCTAssertEqual(queued.first?.state, .failed)
        await sync.stop()
    }
}

private final class MoveFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var failMove: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class MoveFailureTransport: MailTransport, @unchecked Sendable {
    private let base: MailTransport
    private let switcher: MoveFailureSwitch

    init(base: MailTransport, switcher: MoveFailureSwitch) {
        self.base = base; self.switcher = switcher
    }

    func write(_ data: Data) async throws {
        if switcher.failMove, String(decoding: data, as: UTF8.self).contains(" UID MOVE ") {
            throw MailTransportError.closed
        }
        try await base.write(data)
    }

    func read(timeout: TimeInterval) async throws -> Data { try await base.read(timeout: timeout) }
    func startTLS() async throws { try await base.startTLS() }
    func close() { base.close() }
}

private final class CredentialFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Error?
    var failure: Error? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func read() throws -> MailCredential {
        if let failure { throw failure }
        return .password("app-password")
    }
}
