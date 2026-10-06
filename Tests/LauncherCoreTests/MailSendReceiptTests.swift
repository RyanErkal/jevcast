import Foundation
import XCTest
@testable import LauncherCore

final class MailSendReceiptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/jevcast-mail-send-receipt-build", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func account(savesSentCopy: Bool = true, roles: [String: MailMailbox.Role]? = nil) -> NativeMailAccount {
        var value = NativeMailAccount(id: "receipt-account", provider: .other, name: "Me", email: "me@example.com",
                                      imap: MailServer(host: "imap.receipt.test", port: 993, security: .tls),
                                      smtp: MailServer(host: "smtp.receipt.test", port: 465, security: .tls),
                                      savesSentCopy: savesSentCopy)
        value.mailboxRoles = roles
        return value
    }

    private func raw(messageID: String, from: String = "Me <me@example.com>") -> Data {
        Data("From: \(from)\r\nTo: other@example.com\r\nSubject: Receipt\r\nMessage-ID: \(messageID)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBody\r\n".utf8)
    }

    private func makeSync(server: SentReceiptIMAPServer, smtp: FakeSMTPServer,
                          account: NativeMailAccount, boxes: [(String, [String])] = [("Sent", ["\\Sent"])]) async throws -> (MailAccountSync, NativeMailStore, [NativeMailStore.Mailbox]) {
        let store = try NativeMailStore(root: root)
        let entries = boxes.map { IMAPListEntry(flags: $0.1, delimiter: "/", rawName: $0.0) }
        let mapped = try await store.replaceMailboxes(account: account.id, with: entries,
                                                       roles: account.mailboxRoles ?? [:])
        let sync = MailAccountSync(account: account, store: store,
                                   credential: { .password("app-password") },
                                   transport: { host, _, _ in
                                       host == account.imap.host ? server.connect() : smtp.connect()
                                   })
        // An empty, non-visible pass refreshes the list without opening a mailbox or starting a
        // background loop. This keeps the test on the same actor-owned path as production.
        _ = await sync.pass(MailSyncRequest())
        return (sync, store, mapped)
    }

    private func outgoing(id: String = "<receipt@example.com>") -> OutgoingMessage {
        var message = OutgoingMessage(from: .init(name: "Me", address: "me@example.com"),
                                      to: [.init(address: "other@example.com")], subject: "Receipt", body: "Body")
        message.messageID = id
        return message
    }

    func testReceiptCodablePreservesOptionalFilingBaseline() throws {
        let receipt = MailSendReceipt(accountID: "receipt-account", messageID: "<coded@example.com>", sentCopy: .pending,
                                      note: "pending", message: Data("raw".utf8),
                                      date: Date(timeIntervalSince1970: 1_790_000_000), sentMailbox: "Sent",
                                      sentUIDValidity: 7, sentUIDNext: 600_001, filingAttempted: true)
        let copy = try JSONDecoder().decode(MailSendReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(copy, receipt)
    }

    func testSMTPAcceptedAppendRefusalReturnsPendingWithoutResend() async throws {
        let imap = SentReceiptIMAPServer(); imap.appendBehavior = .refusal
        let smtp = FakeSMTPServer()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account())

        let message = outgoing()
        let receipt = try await sync.send(message)
        XCTAssertEqual(receipt.sentCopy, .pending)
        XCTAssertEqual(receipt.message, MailComposer.render(message))
        XCTAssertEqual(smtp.delivered.count, 1)
        XCTAssertEqual(imap.appendCount, 1)
        await sync.stop()
    }

    func testMissingAPPENDUIDReturnsPendingAndNeverRetries() async throws {
        let imap = SentReceiptIMAPServer(); imap.appendBehavior = .missingUID
        let smtp = FakeSMTPServer()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account())

        let receipt = try await sync.send(outgoing())
        XCTAssertEqual(receipt.sentCopy, .pending)
        XCTAssertEqual(smtp.delivered.count, 1)
        XCTAssertEqual(imap.appendCount, 1)
        await sync.stop()
    }

    func testLostAPPENDAcknowledgementReturnsPendingWithoutRetry() async throws {
        let imap = SentReceiptIMAPServer(); imap.appendBehavior = .lostAcknowledgement
        let smtp = FakeSMTPServer()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account())

        let receipt = try await sync.send(outgoing())
        XCTAssertEqual(receipt.sentCopy, .pending)
        XCTAssertEqual(smtp.delivered.count, 1)
        XCTAssertEqual(imap.appendCount, 1)
        await sync.stop()
    }

    func testHighUIDFailedAppendRepairsFromReceiptBaselineWithoutSMTP() async throws {
        let imap = SentReceiptIMAPServer(); imap.nextUID = 600_001; imap.appendBehavior = .missingUID
        let smtp = FakeSMTPServer()
        let account = account()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account)

        let receipt = try await sync.send(outgoing(id: "<high-uid@example.com>"))
        XCTAssertEqual(receipt.sentCopy, .pending)
        XCTAssertEqual(receipt.sentMailbox, "Sent")
        XCTAssertEqual(receipt.sentUIDValidity, 7)
        XCTAssertEqual(receipt.sentUIDNext, 600_001)
        XCTAssertEqual(receipt.filingAttempted, true)

        let repaired = try await sync.repairSentCopy(receipt)
        XCTAssertEqual(repaired.sentCopy, .saved)
        XCTAssertEqual(imap.appendCount, 1, "the bounded duplicate check must avoid a second APPEND")
        XCTAssertLessThanOrEqual(imap.searchCount, 1, "the high UID repair must use the receipt baseline")
        XCTAssertEqual(smtp.delivered.count, 1, "repair must not use SMTP")
        await sync.stop()
    }

    func testSuccessfulAndServerManagedReceipts() async throws {
        let imap = SentReceiptIMAPServer()
        let smtp = FakeSMTPServer()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account())
        let saved = try await sync.send(outgoing())
        XCTAssertEqual(saved.sentCopy, .saved)
        XCTAssertNil(saved.message)
        XCTAssertEqual(imap.appendCount, 1)
        await sync.stop()

        let managedIMAP = SentReceiptIMAPServer()
        let managedSMTP = FakeSMTPServer()
        let (managed, _, _) = try await makeSync(server: managedIMAP, smtp: managedSMTP, account: account(savesSentCopy: false))
        let managedReceipt = try await managed.send(outgoing(id: "<managed@example.com>"))
        XCTAssertEqual(managedReceipt.sentCopy, .serverManaged)
        XCTAssertEqual(managedIMAP.appendCount, 0)
        XCTAssertEqual(managedSMTP.delivered.count, 1)
        await managed.stop()
    }

    func testRepairUsesExactParsedMessageIDAndAppendsOnlyOnceWithoutSMTP() async throws {
        let imap = SentReceiptIMAPServer()
        let smtp = FakeSMTPServer()
        let account = account()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account)
        let data = raw(messageID: "<repair@example.com>")
        let receipt = MailSendReceipt(accountID: account.id, messageID: "<repair@example.com>", sentCopy: .pending,
                                      message: data, date: Date(timeIntervalSince1970: 1_790_000_000))

        let repaired = try await sync.repairSentCopy(receipt)
        XCTAssertEqual(repaired.sentCopy, .saved)
        XCTAssertEqual(imap.appendCount, 1)
        XCTAssertTrue(smtp.delivered.isEmpty, "repair must never call SMTP")
        await sync.stop()
    }

    func testExistingExactMessageIDSuppressesAPPEND() async throws {
        let imap = SentReceiptIMAPServer()
        imap.add(raw: raw(messageID: "<existing@example.com>"))
        let smtp = FakeSMTPServer()
        let account = account()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account)
        let receipt = MailSendReceipt(accountID: account.id, messageID: "<existing@example.com>", sentCopy: .pending,
                                      message: raw(messageID: "<existing@example.com>"))

        _ = try await sync.repairSentCopy(receipt)
        XCTAssertEqual(imap.appendCount, 0)
        await sync.stop()
    }

    func testSubstringSearchFalsePositiveDoesNotSuppressAPPEND() async throws {
        let imap = SentReceiptIMAPServer(); imap.substringSearch = true
        imap.add(raw: raw(messageID: "<substring@example.com.extra>"))
        let smtp = FakeSMTPServer()
        let account = account()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account)
        let receipt = MailSendReceipt(accountID: account.id, messageID: "<substring@example.com>", sentCopy: .pending,
                                      message: raw(messageID: "<substring@example.com>"))

        _ = try await sync.repairSentCopy(receipt)
        XCTAssertEqual(imap.appendCount, 1)
        await sync.stop()
    }

    func testMissingSearchCandidateFetchRefusesAPPEND() async throws {
        let imap = SentReceiptIMAPServer(); imap.fetchBehavior = .omitCandidate
        imap.add(raw: raw(messageID: "<unfetched@example.com>"))
        let smtp = FakeSMTPServer()
        let account = account()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account)
        let receipt = MailSendReceipt(accountID: account.id, messageID: "<unfetched@example.com>", sentCopy: .pending,
                                      message: raw(messageID: "<unfetched@example.com>"))

        await XCTAssertThrowsErrorAsync { _ = try await sync.repairSentCopy(receipt) }
        XCTAssertEqual(imap.appendCount, 0, "an incomplete FETCH cannot prove absence")
        XCTAssertTrue(smtp.delivered.isEmpty)
        await sync.stop()
    }

    func testUnreadableSearchCandidateHeaderRefusesAPPEND() async throws {
        let imap = SentReceiptIMAPServer(); imap.fetchBehavior = .missingMessageID
        imap.add(raw: raw(messageID: "<unreadable@example.com>"))
        let smtp = FakeSMTPServer()
        let account = account()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account)
        let receipt = MailSendReceipt(accountID: account.id, messageID: "<unreadable@example.com>", sentCopy: .pending,
                                      message: raw(messageID: "<unreadable@example.com>"))

        await XCTAssertThrowsErrorAsync { _ = try await sync.repairSentCopy(receipt) }
        XCTAssertEqual(imap.appendCount, 0, "an unreadable Message-ID cannot prove absence")
        XCTAssertTrue(smtp.delivered.isEmpty)
        await sync.stop()
    }

    func testMalformedAndCrossAccountReceiptsRefuseBeforeAPPEND() async throws {
        let imap = SentReceiptIMAPServer()
        let smtp = FakeSMTPServer()
        let account = account()
        let (sync, _, _) = try await makeSync(server: imap, smtp: smtp, account: account)

        let malformed = MailSendReceipt(accountID: account.id, messageID: "not-an-id", sentCopy: .pending,
                                        message: raw(messageID: "not-an-id"))
        await XCTAssertThrowsErrorAsync { _ = try await sync.repairSentCopy(malformed) }
        let crossAccount = MailSendReceipt(accountID: account.id, messageID: "<cross@example.com>", sentCopy: .pending,
                                           message: raw(messageID: "<cross@example.com>", from: "Other <other@example.com>"))
        await XCTAssertThrowsErrorAsync { _ = try await sync.repairSentCopy(crossAccount) }
        XCTAssertEqual(imap.appendCount, 0)
        await sync.stop()
    }

    func testCurrentMappingMissingAndUIDValidityChangeRefuse() async throws {
        let missingIMAP = SentReceiptIMAPServer(mailboxes: [])
        let smtp = FakeSMTPServer()
        let account = account()
        let (missing, _, _) = try await makeSync(server: missingIMAP, smtp: smtp, account: account,
                                                 boxes: [("Sent", ["\\Sent"])])
        let missingSend = try await missing.send(outgoing(id: "<missing-send@example.com>"))
        XCTAssertEqual(missingSend.sentCopy, .pending)
        XCTAssertEqual(missingSend.filingAttempted, false)
        XCTAssertEqual(missingIMAP.appendCount, 0)
        XCTAssertEqual(smtp.delivered.count, 1)
        let missingReceipt = MailSendReceipt(accountID: account.id, messageID: "<missing@example.com>", sentCopy: .pending,
                                             message: raw(messageID: "<missing@example.com>"))
        await XCTAssertThrowsErrorAsync { _ = try await missing.repairSentCopy(missingReceipt) }
        XCTAssertEqual(missingIMAP.appendCount, 0)
        await missing.stop()

        let ambiguousIMAP = SentReceiptIMAPServer(mailboxes: [("Sent", ["\\Sent"]), ("Sent-other", ["\\Sent"])])
        let ambiguousSMTP = FakeSMTPServer()
        let (ambiguous, _, _) = try await makeSync(server: ambiguousIMAP, smtp: ambiguousSMTP, account: account,
                                                   boxes: [("Sent", ["\\Sent"]), ("Sent-other", ["\\Sent"])])
        let ambiguousSend = try await ambiguous.send(outgoing(id: "<ambiguous-send@example.com>"))
        XCTAssertEqual(ambiguousSend.sentCopy, .pending)
        XCTAssertEqual(ambiguousSend.filingAttempted, false)
        XCTAssertEqual(ambiguousIMAP.appendCount, 0)
        XCTAssertEqual(ambiguousSMTP.delivered.count, 1)
        await ambiguous.stop()

        let changedIMAP = SentReceiptIMAPServer(); changedIMAP.uidValidity = 99
        let (changed, store, boxes) = try await makeSync(server: changedIMAP, smtp: FakeSMTPServer(), account: account)
        var stale = boxes[0]; stale.uidValidity = 7
        try await store.saveSyncState(stale)
        let changedReceipt = MailSendReceipt(accountID: account.id, messageID: "<changed@example.com>", sentCopy: .pending,
                                             message: raw(messageID: "<changed@example.com>"))
        await XCTAssertThrowsErrorAsync { _ = try await changed.repairSentCopy(changedReceipt) }
        XCTAssertEqual(changedIMAP.appendCount, 0)
        await changed.stop()
    }

    func testZeroLimitIsClampedAndPartialNonUIDONLYViewRefusesAbsentCopy() async throws {
        let zero = SentReceiptIMAPServer(); zero.capabilities.append("MESSAGELIMIT=0")
        zero.add(raw: raw(messageID: "<zero@example.com>"))
        let smtp = FakeSMTPServer()
        let account = account()
        let (zeroSync, _, _) = try await makeSync(server: zero, smtp: smtp, account: account)
        let zeroReceipt = MailSendReceipt(accountID: account.id, messageID: "<zero@example.com>", sentCopy: .pending,
                                          message: raw(messageID: "<zero@example.com>"))
        _ = try await zeroSync.repairSentCopy(zeroReceipt)
        XCTAssertEqual(zero.appendCount, 0)
        await zeroSync.stop()

        let partial = SentReceiptIMAPServer(); partial.capabilities.append("MESSAGELIMIT=1")
        partial.add(raw: raw(messageID: "<other@example.com>"))
        partial.add(raw: raw(messageID: "<newer@example.com>"))
        let (partialSync, _, _) = try await makeSync(server: partial, smtp: FakeSMTPServer(), account: account)
        let absent = MailSendReceipt(accountID: account.id, messageID: "<absent@example.com>", sentCopy: .pending,
                                     message: raw(messageID: "<absent@example.com>"))
        await XCTAssertThrowsErrorAsync { _ = try await partialSync.repairSentCopy(absent) }
        XCTAssertEqual(partial.appendCount, 0)
        await partialSync.stop()
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(_ expression: @escaping () async throws -> Void,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await expression()
            XCTFail("Expected an error", file: file, line: line)
        } catch {
            // The focused tests only need the refusal boundary. Individual error text remains
            // user-visible and is asserted by the production code's type-level tests.
        }
    }
}

private final class SentReceiptIMAPServer: @unchecked Sendable {
    enum AppendBehavior { case success, refusal, missingUID, lostAcknowledgement }
    enum FetchBehavior: Equatable { case complete, omitCandidate, missingMessageID }
    struct Message { var uid: UInt32; var raw: Data }

    let lock = NSLock()
    var capabilities = ["IMAP4rev1", "LITERAL+", "UIDPLUS", "ESEARCH", "ENABLE", "AUTH=PLAIN", "SASL-IR"]
    var mailboxes: [(String, [String])]
    var messages: [Message] = []
    var uidValidity: UInt32 = 7
    var nextUID: UInt32 = 1
    var appendBehavior: AppendBehavior = .success
    var fetchBehavior: FetchBehavior = .complete
    var substringSearch = false
    private(set) var appendCount = 0
    private(set) var searchCount = 0

    init(mailboxes: [(String, [String])] = [("INBOX", []), ("Sent", ["\\Sent"])]) { self.mailboxes = mailboxes }

    func connect() -> SentReceiptIMAPTransport { SentReceiptIMAPTransport(server: self) }

    func add(raw: Data) {
        lock.withLock { messages.append(.init(uid: nextUID, raw: raw)); nextUID += 1 }
    }

    func mailbox(_ name: String) -> (String, [String])? {
        lock.withLock { mailboxes.first { $0.0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    func recordAppend(_ raw: Data, store: Bool) -> UInt32 {
        lock.withLock {
            appendCount += 1
            let uid = nextUID
            if store {
                nextUID += 1
                messages.append(.init(uid: uid, raw: raw))
            }
            return uid
        }
    }

    func recordSearch() { lock.withLock { searchCount += 1 } }
}

private final class SentReceiptIMAPTransport: MailTransport, @unchecked Sendable {
    private let server: SentReceiptIMAPServer
    private let lock = NSLock()
    private var input: [UInt8] = []
    private var output: [UInt8]
    private var readers: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    init(server: SentReceiptIMAPServer) {
        self.server = server
        output = Array("* OK [CAPABILITY \(server.capabilities.joined(separator: " "))] ready\r\n".utf8)
    }

    func write(_ data: Data) async throws {
        let result: (closed: Bool, readers: [CheckedContinuation<Data, Error>]) = lock.withLock {
            guard !closed else { return (true, []) }
            input += data
            process()
            if closed {
                let pending = readers
                readers.removeAll()
                return (true, pending)
            }
            return (false, takeReaders())
        }
        if result.closed { for reader in result.readers { reader.resume(throwing: MailTransportError.closed) } }
        else { deliver(result.readers) }
    }

    func read(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Data, Error>? = lock.withLock {
                if !output.isEmpty { defer { output.removeAll() }; return .success(Data(output)) }
                if closed { return .failure(MailTransportError.closed) }
                readers.append(continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func startTLS() async throws {}

    func close() {
        let pending: [CheckedContinuation<Data, Error>] = lock.withLock {
            closed = true
            defer { readers.removeAll() }
            return readers
        }
        for reader in pending { reader.resume(throwing: MailTransportError.closed) }
    }

    private func takeReaders() -> [CheckedContinuation<Data, Error>] {
        guard !output.isEmpty, !readers.isEmpty else { return [] }
        defer { readers.removeAll() }
        return readers
    }

    private func deliver(_ readers: [CheckedContinuation<Data, Error>]) {
        guard let first = readers.first else { return }
        let data: Data = lock.withLock { defer { output.removeAll() }; return Data(output) }
        first.resume(returning: data)
    }

    private func send(_ text: String) { output += Array(text.utf8) }

    private func process() {
        while !closed {
            var framer = IMAPFramer(); framer.append(Data(input))
            guard let command = try? framer.next() else { return }
            input.removeFirst(command.count)
            handle(command)
        }
    }

    private func handle(_ bytes: [UInt8]) {
        var parser = IMAPParser(bytes: bytes)
        let tag = parser.word()
        var values: [IMAPValue] = []
        while let value = (try? parser.nextArgument()) ?? nil { values.append(value) }
        guard let first = values.first?.text?.uppercased() else { send("\(tag) BAD empty\r\n"); return }
        var name = first
        var args = Array(values.dropFirst())
        if name == "UID", let second = args.first?.text?.uppercased() { name = "UID " + second; args.removeFirst() }

        switch name {
        case "CAPABILITY": send("* CAPABILITY \(server.capabilities.joined(separator: " "))\r\n\(tag) OK capabilities\r\n")
        case "ENABLE":
            let enabled = args.compactMap(\.text).map { $0.uppercased() }.filter(server.capabilities.contains)
            send("* ENABLED \(enabled.joined(separator: " "))\r\n\(tag) OK enabled\r\n")
        case "AUTHENTICATE": send("\(tag) OK signed in\r\n")
        case "LOGIN": send("\(tag) OK signed in\r\n")
        case "LIST":
            for mailbox in server.mailboxes {
                send("* LIST (\\HasNoChildren\(mailbox.1.map { " " + $0 }.joined())) \"/\" \"\(mailbox.0)\"\r\n")
            }
            send("\(tag) OK list\r\n")
        case "SELECT":
            guard let mailbox = args.first?.text, server.mailbox(mailbox) != nil else { send("\(tag) NO missing\r\n"); return }
            let count = server.lock.withLock { server.messages.count }
            send("* \(count) EXISTS\r\n* OK [UIDVALIDITY \(server.uidValidity)] valid\r\n* OK [UIDNEXT \(server.nextUID)] next\r\n\(tag) OK [READ-WRITE] selected\r\n")
        case "UID SEARCH": search(tag: tag, args: args)
        case "UID FETCH": fetch(tag: tag, args: args)
        case "APPEND": append(tag: tag, args: args)
        case "LOGOUT": send("* BYE bye\r\n\(tag) OK logout\r\n")
        default: send("\(tag) OK noop\r\n")
        }
    }

    private func search(tag: String, args: [IMAPValue]) {
        server.recordSearch()
        let range = args.firstIndex { $0.text?.uppercased() == "UID" }.flatMap { index -> String? in
            guard index + 1 < args.count else { return nil }
            return args[index + 1].text
        }
        let bounds = range?.split(separator: ":").compactMap { UInt32($0) } ?? []
        let low = bounds.first ?? 1, high = bounds.last ?? UInt32.max
        let query = args.last?.text ?? ""
        let found = server.lock.withLock {
            server.messages.filter { message in
                guard (low...high).contains(message.uid) else { return false }
                let header = String(decoding: MIMEMessage.splitHeaders(message.raw).0, as: UTF8.self)
                if server.substringSearch { return header.contains(query.replacingOccurrences(of: ">", with: "")) }
                return header.contains("Message-ID: \(query)")
            }.map(\.uid)
        }
        if server.capabilities.contains("ESEARCH") {
            let all = found.map(String.init).joined(separator: ",")
            send("* ESEARCH (TAG \"\(tag)\") UID\(all.isEmpty ? "" : " ALL \(all)")\r\n")
        } else { send("* SEARCH\(found.map { " \($0)" }.joined())\r\n") }
        send("\(tag) OK search\r\n")
    }

    private func fetch(tag: String, args: [IMAPValue]) {
        guard let set = args.first?.text else { send("\(tag) BAD fetch\r\n"); return }
        let wanted = set.split(separator: ",").flatMap { part -> [UInt32] in
            let bounds = part.split(separator: ":").compactMap { UInt32($0) }
            guard let first = bounds.first, let last = bounds.last else { return [] }
            return Array(min(first, last)...max(first, last))
        }
        let items = server.lock.withLock { server.messages.filter { wanted.contains($0.uid) } }
        for (sequence, message) in items.enumerated() {
            if server.fetchBehavior == .omitCandidate { continue }
            let header: Data
            if server.fetchBehavior == .missingMessageID {
                header = Data("Subject: no message id\r\n\r\n".utf8)
            } else {
                header = MIMEMessage.splitHeaders(message.raw).0 + Data("\r\n\r\n".utf8)
            }
            send("* \(sequence + 1) FETCH (UID \(message.uid) BODY[HEADER.FIELDS (MESSAGE-ID)] {\(header.count)}\r\n")
            output += Array(header)
            send(")\r\n")
        }
        send("\(tag) OK fetch\r\n")
    }

    private func append(tag: String, args: [IMAPValue]) {
        guard let data = args.last?.data else { send("\(tag) NO append\r\n"); return }
        switch server.appendBehavior {
        case .success:
            let uid = server.recordAppend(data, store: true)
            send("\(tag) OK [APPENDUID \(server.uidValidity) \(uid)] appended\r\n")
        case .refusal:
            _ = server.recordAppend(data, store: false)
            send("\(tag) NO append refused\r\n")
        case .missingUID:
            _ = server.recordAppend(data, store: true)
            send("\(tag) OK appended\r\n")
        case .lostAcknowledgement:
            _ = server.recordAppend(data, store: true)
            closed = true
        }
    }
}
