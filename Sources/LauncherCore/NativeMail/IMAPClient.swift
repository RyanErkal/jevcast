import Foundation

/// One IMAP connection. Commands run one at a time, in order, including when several tasks ask at
/// once: sync and a user's change share the connection between commands. It connects on first
/// use and again after the connection drops. Mailbox commands select their mailbox first.
public actor IMAPClient {
    public typealias TransportFactory = @Sendable (_ host: String, _ port: Int, _ tls: Bool) -> MailTransport
    public static let networkTransport: TransportFactory = {
        MailIOPolicy.isOffline ? OfflineMailTransport() : StreamTaskTransport(host: $0, port: $1, tls: $2)
    }

    public struct Settings: Sendable, Equatable {
        public var server: MailServer
        public var username: String
        public init(server: MailServer, username: String) { self.server = server; self.username = username }
    }

    /// A selected mailbox as SELECT reported it.
    public struct MailboxInfo: Sendable, Equatable {
        public var name: String
        public var uidValidity: UInt32
        public var uidNext: UInt32?
        public var exists: UInt32
        public var highestModSeq: UInt64?
        public var readOnly: Bool
    }

    /// A finished command: its untagged data and its closing status.
    struct Reply { var untagged: [IMAPUntagged]; var status: IMAPStatusText }

    let settings: Settings
    private let credential: @Sendable () async throws -> MailCredential
    private let makeTransport: TransportFactory
    let readTimeout: TimeInterval
    var transport: MailTransport?
    var framer = IMAPFramer()
    private var tagNumber = 0
    public private(set) var capabilities: Set<String> = []
    /// True once the server turned on UIDONLY (RFC 9586): commands then name messages only by UID,
    /// and a server such as Yahoo shows every message, not only the newest thousand.
    public private(set) var uidOnly = false
    var selected: MailboxInfo?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(settings: Settings, credential: @escaping @Sendable () async throws -> MailCredential,
                transport: @escaping TransportFactory = IMAPClient.networkTransport, readTimeout: TimeInterval = 60) {
        self.settings = settings
        self.credential = credential
        self.makeTransport = transport
        self.readTimeout = readTimeout
    }

    public var isConnected: Bool { transport != nil }

    public func has(_ capability: String) -> Bool { capabilities.contains(capability.uppercased()) }

    /// The most messages one command may name or return (RFC 9738 MESSAGELIMIT), such as Yahoo's
    /// 1000. A search that would find more is refused or cut short.
    public var messageLimit: Int? {
        capabilities.lazy.compactMap { $0.hasPrefix("MESSAGELIMIT=") ? Int($0.dropFirst("MESSAGELIMIT=".count)) : nil }.first
    }

    // MARK: One command at a time

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Runs `body` alone on a connected session. A dropped connection is opened again and `body`
    /// runs once more when `retry` is true, which suits commands that do the same thing twice.
    func exclusive<T>(retry: Bool = true, _ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if transport == nil { try await connect() }
        do { return try await body() } catch let error where retry && Self.isConnectionError(error) {
            try await connect()
            return try await body()
        }
    }

    static func isConnectionError(_ error: Error) -> Bool {
        if error is MailTransportError { return true }
        if let mail = error as? MailError { return mail.isTransient }
        return false
    }

    // MARK: Connecting

    /// Checks the server and the sign-in, for Settings. Leaves the connection open for use.
    public func verify() async throws {
        try await exclusive(retry: false) {}
    }

    public func logout() async {
        await acquire()
        defer { release() }
        if transport != nil { _ = try? await execute(IMAPCommand("LOGOUT")) }
        disconnect()
    }

    /// Drops the connection without LOGOUT, such as after the Mac wakes, when the old one is
    /// likely dead. A command waiting on it fails and the next one connects again.
    public func drop() { disconnect() }

    func disconnect() {
        transport?.close()
        transport = nil
        selected = nil
        uidOnly = false
        framer = IMAPFramer()
    }

    private func connect() async throws {
        disconnect()
        let server = try settings.server.validated()
        let transport = makeTransport(server.host, server.port, server.security == .tls)
        self.transport = transport
        do {
            let greeting = try await next()
            guard case .untagged(.status(let status)) = greeting else { throw MailError.unexpected("no greeting") }
            if status.status == .bye { throw MailError.serverClosed(status.text) }
            guard status.status == .ok || status.status == .preauth else { throw MailError.unexpected("greeting \(status.status.rawValue)") }
            capabilities = Self.capabilities(from: status.code) ?? []
            if server.security == .startTLS {
                if capabilities.isEmpty { try await refreshCapabilities() }
                guard has("STARTTLS") else { throw MailError.noSecureConnection(host: server.host) }
                _ = try await execute(IMAPCommand("STARTTLS"))
                try await transport.startTLS()
                // Anything that arrived before TLS is dropped, so it cannot pose as a reply.
                framer = IMAPFramer()
                capabilities = []
                try await refreshCapabilities()
            }
            if capabilities.isEmpty { try await refreshCapabilities() }
            if status.status != .preauth {
                let reply = try await authenticate()
                capabilities = Self.capabilities(from: reply.status.code) ?? []
                if capabilities.isEmpty { try await refreshCapabilities() }
            }
            let wanted = ["CONDSTORE", "UIDONLY"].filter(has)
            if has("ENABLE"), !wanted.isEmpty, let reply = try? await execute(IMAPCommand("ENABLE").raw(wanted.joined(separator: " "))) {
                for case .enabled(let list) in reply.untagged where list.contains(where: { $0.uppercased() == "UIDONLY" }) { uidOnly = true }
            }
        } catch {
            disconnect()
            throw error
        }
    }

    private func refreshCapabilities() async throws {
        let reply = try await execute(IMAPCommand("CAPABILITY"))
        for case .capability(let list) in reply.untagged { capabilities = Set(list.map { $0.uppercased() }) }
    }

    static func capabilities(from code: IMAPResponseCode?) -> Set<String>? {
        guard let code, code.name == "CAPABILITY" else { return nil }
        return Set(code.values.compactMap { $0.text?.uppercased() })
    }

    private func authenticate() async throws -> Reply {
        let username = settings.username
        do {
            switch try await credential() {
            case .password(let password):
                if has("AUTH=PLAIN") {
                    let payload = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
                    if has("SASL-IR") { return try await execute(IMAPCommand("AUTHENTICATE").raw("PLAIN").raw(payload)) }
                    return try await execute(IMAPCommand("AUTHENTICATE").raw("PLAIN")) { _ in Data(payload.utf8) }
                }
                if has("LOGINDISABLED") { throw MailError.signInFailed("The server does not accept a password.") }
                return try await execute(IMAPCommand("LOGIN").string(username).string(password))
            case .oauth2(let token):
                let payload = Data("user=\(username)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
                guard has("AUTH=XOAUTH2") else { throw MailError.signInFailed("The server does not offer OAuth sign-in.") }
                // On failure the server sends an error as a continuation; an empty line ends the exchange.
                if has("SASL-IR") { return try await execute(IMAPCommand("AUTHENTICATE").raw("XOAUTH2").raw(payload)) { _ in Data() } }
                var sent = false
                return try await execute(IMAPCommand("AUTHENTICATE").raw("XOAUTH2")) { _ in
                    defer { sent = true }
                    return sent ? Data() : Data(payload.utf8)
                }
            }
        } catch MailError.commandFailed {
            throw MailError.signInFailed("Check the sign-in details and the account's IMAP access.")
        }
    }

    // MARK: Commands

    /// Writes `command` and reads until its tagged reply. `onContinuation` answers a "+" that is
    /// not a literal go-ahead, as AUTHENTICATE needs; nil cancels the exchange.
    func execute(_ command: IMAPCommand, onContinuation: ((String) -> Data?)? = nil) async throws -> Reply {
        guard let transport else { throw MailTransportError.closed }
        tagNumber += 1
        let tag = "J\(tagNumber)"
        var segments = command.segments(tag: tag, literalPlus: has("LITERAL+"))[...]
        var untagged: [IMAPUntagged] = []
        do {
            let first = segments.removeFirst()
            try await transport.write(first.data)
            var waiting = first.waitsForContinuation
            while true {
                switch try await next() {
                case .continuation(let text):
                    if waiting, let segment = segments.popFirst() {
                        try await transport.write(segment.data)
                        waiting = segment.waitsForContinuation
                    } else {
                        var answer = onContinuation?(text) ?? Data("*".utf8)
                        answer.append(contentsOf: [Byte.cr, Byte.lf])
                        try await transport.write(answer)
                    }
                case .untagged(let data):
                    observe(data)
                    untagged.append(data)
                case .tagged(let replyTag, let status):
                    guard replyTag == tag else { continue }
                    if let list = Self.capabilities(from: status.code) { capabilities = list }
                    guard status.status == .ok else {
                        throw MailError.commandFailed(command: command.name, status: status.status, text: status.text)
                    }
                    return Reply(untagged: untagged, status: status)
                }
            }
        } catch let error as MailError {
            if case .serverClosed = error { disconnect() }
            throw error
        } catch {
            disconnect()
            throw error
        }
    }

    /// Keeps the selected mailbox's count current, and notes a server that is closing.
    private func observe(_ data: IMAPUntagged) {
        switch data {
        case .exists(let count): selected?.exists = count
        case .expunge: if let count = selected?.exists, count > 0 { selected?.exists = count - 1 }
        case .vanished(let earlier, let set): if !earlier, let count = selected?.exists { selected?.exists = count - UInt32(min(Int(count), set.count)) }
        case .capability(let list): capabilities = Set(list.map { $0.uppercased() })
        default: break
        }
    }

    /// The next reply. An untagged line that does not parse is skipped: the framer already cut it
    /// out, so the session stays in step.
    func next(timeout: TimeInterval? = nil) async throws -> IMAPResponse {
        while true {
            if let bytes = try framer.next() {
                do {
                    let response = try IMAPParser.parse(bytes)
                    if case .untagged(.status(let status)) = response, status.status == .bye {
                        throw MailError.serverClosed(status.text)
                    }
                    return response
                } catch let error as IMAPParseError {
                    if bytes.first == Byte.star { continue }
                    throw MailError.unexpected(error.description)
                }
            }
            guard let transport else { throw MailTransportError.closed }
            framer.append(try await transport.read(timeout: timeout ?? readTimeout))
        }
    }
}
