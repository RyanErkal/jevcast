import Foundation
@testable import LauncherCore

/// An in-memory IMAP server for tests. It answers the commands `IMAPClient` sends, keeps real
/// UIDs, flags, and mod-sequences, and pushes EXISTS to connections waiting in IDLE.
final class FakeIMAPServer: @unchecked Sendable {
    struct Message { var uid: UInt32; var flags: Set<String>; var raw: Data; var date: Date; var modSeq: UInt64 }
    final class Mailbox {
        let name: String; let attributes: [String]
        var uidValidity: UInt32; var nextUID: UInt32 = 1
        var messages: [Message] = []
        init(name: String, attributes: [String], uidValidity: UInt32) { self.name = name; self.attributes = attributes; self.uidValidity = uidValidity }
    }

    let lock = NSLock()
    var capabilities = ["IMAP4rev1", "LITERAL+", "UIDPLUS", "MOVE", "IDLE", "ESEARCH", "AUTH=PLAIN", "SASL-IR", "CONDSTORE", "ENABLE"]
    var mailboxes: [Mailbox] = []
    var password = "app-password"
    var modSeq: UInt64 = 100
    /// Like Yahoo: without UIDONLY a mailbox shows only its newest this-many messages.
    var visibleLimit: Int?
    /// Command names in order, such as "UID FETCH", for asserting what the client did.
    private(set) var log: [String] = []
    private(set) var connections = 0
    private var live: [WeakTransport] = []
    struct WeakTransport { weak var transport: FakeIMAPTransport? }

    init(mailboxes: [(String, [String])] = [("INBOX", []), ("Archive", ["\\Archive"]), ("Sent", ["\\Sent"]), ("Trash", ["\\Trash"])]) {
        self.mailboxes = mailboxes.enumerated().map { Mailbox(name: $0.element.0, attributes: $0.element.1, uidValidity: 1000 + UInt32($0.offset)) }
    }

    var factory: IMAPClient.TransportFactory { { [self] _, _, _ in self.connect() } }

    func connect() -> FakeIMAPTransport {
        let transport = FakeIMAPTransport(server: self)
        lock.withLock { connections += 1; live.append(WeakTransport(transport: transport)) }
        return transport
    }

    func mailbox(_ name: String) -> Mailbox? { mailboxes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// Adds a message as if it arrived, and tells IDLE connections.
    @discardableResult
    func deliver(to name: String, subject: String, from: String = "Sam <sam@example.com>", body: String = "Hello",
                 flags: Set<String> = [], date: Date = Date(timeIntervalSince1970: 1_790_000_000), messageID: String? = nil) -> UInt32 {
        let raw = """
        From: \(from)\r
        To: me@example.com\r
        Subject: \(subject)\r
        Message-ID: \(messageID ?? "<\(UUID().uuidString)@example.com>")\r
        Date: Tue, 29 Sep 2026 06:00:00 +0000\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(body)\r

        """
        let (uid, idlers) = lock.withLock { () -> (UInt32, [FakeIMAPTransport]) in
            let box = mailbox(name)!
            modSeq += 1
            let uid = box.nextUID
            box.nextUID += 1
            box.messages.append(Message(uid: uid, flags: flags, raw: Data(raw.utf8), date: date, modSeq: modSeq))
            return (uid, live.compactMap(\.transport).filter { $0.isIdling(in: name) })
        }
        for transport in idlers { transport.push("* \(mailbox(name)!.messages.count) EXISTS\r\n") }
        return uid
    }

    func setFlags(_ flags: Set<String>, uid: UInt32, in name: String) {
        lock.withLock {
            modSeq += 1
            let box = mailbox(name)!
            if let index = box.messages.firstIndex(where: { $0.uid == uid }) { box.messages[index].flags = flags; box.messages[index].modSeq = modSeq }
        }
    }

    func expungeExternally(uid: UInt32, in name: String) {
        lock.withLock { mailbox(name)!.messages.removeAll { $0.uid == uid } }
    }

    func record(_ name: String) { log.append(name) }
    func commands(_ name: String) -> Int { lock.withLock { log.filter { $0 == name }.count } }
}

/// One client connection to `FakeIMAPServer`.
final class FakeIMAPTransport: MailTransport, @unchecked Sendable {
    private let server: FakeIMAPServer
    private var input: [UInt8] = []
    private var output: [UInt8] = []
    private var readers: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    private var selected: FakeIMAPServer.Mailbox?
    private var idleTag: String?
    private var sentGoAhead = false
    private var uidOnly = false
    private var lock: NSLock { server.lock }

    init(server: FakeIMAPServer) {
        self.server = server
        output = Array("* OK [CAPABILITY \(server.capabilities.joined(separator: " "))] Fake ready\r\n".utf8)
    }

    func isIdling(in name: String) -> Bool { idleTag != nil && selected?.name.caseInsensitiveCompare(name) == .orderedSame }

    func write(_ data: Data) async throws {
        let wake: [CheckedContinuation<Data, Error>] = try lock.withLock {
            guard !closed else { throw MailTransportError.closed }
            input += data
            process()
            return takeReaders()
        }
        deliver(wake)
    }

    func read(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Data? = lock.withLock {
                if !output.isEmpty { defer { output = [] }; return Data(output) }
                if closed { return nil }
                readers.append(continuation)
                return Data()
            }
            if let ready, !ready.isEmpty { continuation.resume(returning: ready) }
            else if ready == nil { continuation.resume(throwing: MailTransportError.closed) }
        }
    }

    func startTLS() async throws {}

    func close() {
        let waiting: [CheckedContinuation<Data, Error>] = lock.withLock { closed = true; defer { readers = [] }; return readers }
        for reader in waiting { reader.resume(throwing: MailTransportError.closed) }
    }

    /// Server-initiated data, such as EXISTS during IDLE.
    func push(_ text: String) {
        let wake: [CheckedContinuation<Data, Error>] = lock.withLock { output += Array(text.utf8); return takeReaders() }
        deliver(wake)
    }

    private func takeReaders() -> [CheckedContinuation<Data, Error>] {
        guard !output.isEmpty, !readers.isEmpty else { return [] }
        defer { readers = [] }
        return readers
    }

    private func deliver(_ wake: [CheckedContinuation<Data, Error>]) {
        guard let first = wake.first else { return }
        let data: Data = lock.withLock { defer { output = [] }; return Data(output) }
        first.resume(returning: data)
    }

    private func send(_ text: String) { output += Array(text.utf8) }

    // MARK: Commands (called with the lock held)

    private func process() {
        while true {
            if let tag = idleTag {
                guard let lf = input.firstIndex(of: 0x0A) else { return }
                let line = String(decoding: input[0..<lf], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                input.removeSubrange(0...lf)
                if line.uppercased() == "DONE" { idleTag = nil; send("\(tag) OK IDLE done\r\n") }
                continue
            }
            var framer = IMAPFramer()
            framer.append(Data(input))
            guard let command = try? framer.next() else {
                // A synchronizing literal waits for the go-ahead.
                if !sentGoAhead, let text = String(bytes: input, encoding: .utf8), text.range(of: #"\{\d+\}\r\n$"#, options: .regularExpression) != nil {
                    sentGoAhead = true
                    send("+ Ready\r\n")
                }
                return
            }
            sentGoAhead = false
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
        server.record(name)
        switch name {
        case "CAPABILITY": send("* CAPABILITY \(server.capabilities.joined(separator: " "))\r\n\(tag) OK done\r\n")
        case "ENABLE":
            let asked = args.compactMap(\.text).map { $0.uppercased() }.filter(server.capabilities.contains)
            if asked.contains("UIDONLY") { uidOnly = true }
            send("* ENABLED \(asked.joined(separator: " "))\r\n\(tag) OK enabled\r\n")
        case "NOOP": send("\(tag) OK noop\r\n")
        case "LOGOUT": send("* BYE bye\r\n\(tag) OK logout\r\n")
        case "AUTHENTICATE":
            let payload = args.count > 1 ? Data(base64Encoded: args[1].text ?? "") : nil
            let parts = payload.map { String(decoding: $0, as: UTF8.self).split(separator: "\u{0}", omittingEmptySubsequences: false) } ?? []
            if parts.count == 3, parts[2] == server.password { send("\(tag) OK [CAPABILITY \(server.capabilities.joined(separator: " "))] signed in\r\n") }
            else { send("\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials\r\n") }
        case "LOGIN":
            if args.count == 2, args[1].text == server.password { send("\(tag) OK signed in\r\n") } else { send("\(tag) NO [AUTHENTICATIONFAILED] bad\r\n") }
        case "LIST":
            for box in server.mailboxes {
                send("* LIST (\\HasNoChildren\(box.attributes.map { " " + $0 }.joined())) \"/\" \"\(box.name)\"\r\n")
            }
            send("\(tag) OK list\r\n")
        case "SELECT":
            guard let name = args.first?.text, let box = server.mailbox(name) else { send("\(tag) NO no such mailbox\r\n"); return }
            selected = box
            let highest = box.messages.map(\.modSeq).max() ?? server.modSeq
            send("* \(visible(box).count) EXISTS\r\n* OK [UIDVALIDITY \(box.uidValidity)] ok\r\n* OK [UIDNEXT \(box.nextUID)] ok\r\n")
            if server.capabilities.contains("CONDSTORE") { send("* OK [HIGHESTMODSEQ \(highest)] ok\r\n") }
            send("\(tag) OK [READ-WRITE] selected\r\n")
        case "IDLE":
            idleTag = tag
            send("+ idling\r\n")
        case "UID SEARCH", "UID FETCH", "UID STORE", "UID MOVE", "UID COPY", "UID EXPUNGE", "FETCH", "EXPUNGE":
            guard let box = selected else { send("\(tag) BAD nothing selected\r\n"); return }
            mailboxCommand(name, tag: tag, args: args, box: box)
        case "APPEND":
            guard let name = args.first?.text, let box = server.mailbox(name), let data = args.last?.data else { send("\(tag) NO append\r\n"); return }
            let flags = Set(args.dropFirst().first?.list?.compactMap(\.text) ?? [])
            server.modSeq += 1
            let uid = box.nextUID
            box.nextUID += 1
            box.messages.append(.init(uid: uid, flags: flags, raw: data, date: Date(), modSeq: server.modSeq))
            send("\(tag) OK [APPENDUID \(box.uidValidity) \(uid)] appended\r\n")
        default: send("\(tag) BAD unknown \(name)\r\n")
        }
    }

    /// The messages this connection may see: all with UIDONLY or no limit, else the newest few.
    private func visible(_ box: FakeIMAPServer.Mailbox) -> [FakeIMAPServer.Message] {
        guard let limit = server.visibleLimit, !uidOnly else { return box.messages }
        return Array(box.messages.suffix(limit))
    }

    private func uids(_ text: String, in box: FakeIMAPServer.Mailbox) -> [UInt32] {
        let shown = visible(box)
        let highest = shown.map(\.uid).max() ?? 0
        var result: [UInt32] = []
        for part in text.split(separator: ",") {
            let ends = part.split(separator: ":").map { $0 == "*" ? highest : UInt32($0) ?? 0 }
            let low = min(ends[0], ends.last!), high = max(ends[0], ends.last!)
            result += shown.map(\.uid).filter { $0 >= low && $0 <= high }
        }
        return result
    }

    private func mailboxCommand(_ name: String, tag: String, args: [IMAPValue], box: FakeIMAPServer.Mailbox) {
        if uidOnly, name == "FETCH" || (args.first?.text?.contains("*") ?? false) {
            send("\(tag) BAD [UIDREQUIRED] Message numbers are not allowed once UIDONLY is enabled\r\n")
            return
        }
        switch name {
        case "UID SEARCH":
            var found = visible(box).map(\.uid)
            if let index = args.firstIndex(where: { $0.text?.uppercased() == "UID" }), index + 1 < args.count, let set = args[index + 1].text {
                found = uids(set, in: box)
            }
            if args.first?.text?.uppercased() == "RETURN" {
                let set = IMAPSequenceSet(found)
                send("* ESEARCH (TAG \"\(tag)\") UID" + (set.isEmpty ? "" : " ALL \(set)") + "\r\n")
            } else {
                send("* SEARCH" + found.map { " \($0)" }.joined() + "\r\n")
            }
            send("\(tag) OK search\r\n")
        case "UID FETCH", "FETCH":
            guard let setText = args.first?.text, let items = args.dropFirst().first else { send("\(tag) BAD fetch\r\n"); return }
            let itemText = (items.list ?? [items]).compactMap(\.text).joined(separator: " ").uppercased()
            var changedSince: UInt64?
            if let last = args.last?.list, last.first?.text?.uppercased() == "CHANGEDSINCE" { changedSince = last.dropFirst().first?.number }
            let chosen: [UInt32]
            if name == "FETCH" {
                let ends = setText.split(separator: ":").compactMap { Int($0) }
                let shown = visible(box)
                chosen = (ends[0]...ends.last!).compactMap { $0 >= 1 && $0 <= shown.count ? shown[$0 - 1].uid : nil }
            } else {
                chosen = uids(setText, in: box)
            }
            for (index, message) in box.messages.enumerated() where chosen.contains(message.uid) {
                if let changedSince, message.modSeq <= changedSince { continue }
                var parts = ["UID \(message.uid)", "FLAGS (\(message.flags.sorted().joined(separator: " ")))"]
                if itemText.contains("INTERNALDATE") { parts.append("INTERNALDATE \"\(IMAPDate.format(message.date))\"") }
                if itemText.contains("RFC822.SIZE") { parts.append("RFC822.SIZE \(message.raw.count)") }
                var literal: Data?
                if itemText.contains("HEADER.FIELDS") {
                    let header = MIMEMessage.splitHeaders(message.raw).0 + Data("\r\n\r\n".utf8)
                    parts.append("BODY[HEADER.FIELDS (DATE FROM)] {\(header.count)}")
                    literal = header
                } else if itemText.contains("BODY.PEEK[]") {
                    parts.append("BODY[] {\(message.raw.count)}")
                    literal = message.raw
                }
                send(uidOnly ? "* \(message.uid) UIDFETCH (" + parts.joined(separator: " ") : "* \(index + 1) FETCH (" + parts.joined(separator: " "))
                if let literal { send("\r\n"); output += Array(literal) }
                send(")\r\n")
            }
            send("\(tag) OK fetch\r\n")
        case "UID STORE":
            guard args.count >= 3, let set = args[0].text, let mode = args[1].text, let flags = args[2].list?.compactMap(\.text) else { send("\(tag) BAD store\r\n"); return }
            let targets = uids(set, in: box)
            for index in box.messages.indices where targets.contains(box.messages[index].uid) {
                server.modSeq += 1
                if mode.hasPrefix("+") { box.messages[index].flags.formUnion(flags) } else { box.messages[index].flags.subtract(flags) }
                box.messages[index].modSeq = server.modSeq
            }
            send("\(tag) OK store\r\n")
        case "UID MOVE", "UID COPY":
            guard args.count == 2, let set = args[0].text, let destinationName = args[1].text, let destination = server.mailbox(destinationName) else {
                send("\(tag) NO [TRYCREATE] no mailbox\r\n"); return
            }
            let targets = uids(set, in: box)
            for message in box.messages where targets.contains(message.uid) {
                server.modSeq += 1
                destination.messages.append(.init(uid: destination.nextUID, flags: message.flags, raw: message.raw, date: message.date, modSeq: server.modSeq))
                destination.nextUID += 1
            }
            if name == "UID MOVE" {
                for uid in targets {
                    if let index = box.messages.firstIndex(where: { $0.uid == uid }) {
                        box.messages.remove(at: index)
                        send(uidOnly ? "* VANISHED \(uid)\r\n" : "* \(index + 1) EXPUNGE\r\n")
                    }
                }
            }
            send("\(tag) OK done\r\n")
        case "UID EXPUNGE", "EXPUNGE":
            let targets = name == "EXPUNGE" ? box.messages.map(\.uid) : uids(args.first?.text ?? "", in: box)
            while let index = box.messages.firstIndex(where: { targets.contains($0.uid) && $0.flags.contains("\\Deleted") }) {
                let uid = box.messages[index].uid
                box.messages.remove(at: index)
                send(uidOnly ? "* VANISHED \(uid)\r\n" : "* \(index + 1) EXPUNGE\r\n")
            }
            send("\(tag) OK expunged\r\n")
        default: send("\(tag) BAD\r\n")
        }
    }
}
