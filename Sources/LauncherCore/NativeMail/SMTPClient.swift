import Foundation

/// Sends one message per session over SMTP: greet, secure, sign in, send, quit. Sending is rare
/// and a session is short, so no connection is kept open between messages.
public struct SMTPClient: Sendable {
    public struct Settings: Sendable, Equatable {
        public var server: MailServer
        public var username: String
        public init(server: MailServer, username: String) { self.server = server; self.username = username }
    }

    let settings: Settings
    let credential: @Sendable () async throws -> MailCredential
    let makeTransport: IMAPClient.TransportFactory
    let timeout: TimeInterval

    public init(settings: Settings, credential: @escaping @Sendable () async throws -> MailCredential,
                transport: @escaping IMAPClient.TransportFactory = IMAPClient.networkTransport, timeout: TimeInterval = 60) {
        self.settings = settings; self.credential = credential; self.makeTransport = transport; self.timeout = timeout
    }

    /// Signs in and quits, for Settings.
    public func verify() async throws {
        let session = try await open()
        defer { session.close() }
        _ = try? await session.command("QUIT")
    }

    /// Sends `message` (RFC 5322 bytes with CRLF line ends) from `from` to every address in `recipients`.
    public func send(from: String, recipients: [String], message: Data) async throws {
        guard !recipients.isEmpty else { throw MailError.unexpected("no recipients") }
        for address in [from] + recipients where !SMTPClient.isSafeAddress(address) {
            throw MailError.notFound("“\(address)” cannot be used as an email address.")
        }
        let session = try await open()
        defer { session.close() }
        if let maximum = session.extensions["SIZE"].flatMap(Int.init), maximum > 0, message.count > maximum {
            throw MailError.notFound("This message is larger than the outgoing server allows. Reduce its text or attachments.")
        }
        let eightBit = session.extensions.keys.contains("8BITMIME") && message.contains(where: { $0 >= 0x80 })
        try await session.expect(session.command("MAIL FROM:<\(from)>" + (eightBit ? " BODY=8BITMIME" : "")), 250)
        for address in recipients {
            let reply = try await session.command("RCPT TO:<\(address)>")
            guard reply.code == 250 || reply.code == 251 else {
                throw MailError.smtp(code: reply.code, text: "\(address) was refused. " + reply.text)
            }
        }
        try await session.expect(session.command("DATA"), 354)
        // From the first DATA byte onward, a broken connection cannot prove that nothing was sent.
        do {
            try await session.write(SMTPClient.dotStuffed(message))
            let reply = try await session.read()
            try session.expect(reply, 250)
        } catch let error as MailError {
            if case .smtp(let code, _) = error, (400...599).contains(code) { throw error }
            throw MailError.deliveryUncertain
        } catch { throw MailError.deliveryUncertain }
        _ = try? await session.command("QUIT")
    }

    private func open() async throws -> SMTPSession {
        let server = try settings.server.validated()
        let session = SMTPSession(transport: makeTransport(server.host, server.port, server.security == .tls), timeout: timeout)
        do {
            try await session.expect(session.read(), 220)
            try await session.hello()
            if server.security == .startTLS {
                guard session.extensions.keys.contains("STARTTLS") else { throw MailError.noSecureConnection(host: server.host) }
                try await session.expect(session.command("STARTTLS"), 220)
                try await session.startTLS()
                try await session.hello()
            }
            do { try await authenticate(session) }
            catch MailError.smtp { throw MailError.signInFailed("Check the sign-in details and the account's SMTP access.") }
            catch MailError.unexpected { throw MailError.signInFailed("The outgoing server did not complete sign-in.") }
            return session
        } catch {
            session.close()
            throw error
        }
    }

    private func authenticate(_ session: SMTPSession) async throws {
        let methods = Set((session.extensions["AUTH"] ?? "").uppercased().split(separator: " ").map(String.init))
        let username = settings.username
        let reply: SMTPReply
        switch try await credential() {
        case .password(let password):
            if methods.contains("PLAIN") || methods.isEmpty {
                reply = try await session.command("AUTH PLAIN " + Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString(), secret: true)
            } else if methods.contains("LOGIN") {
                try await session.expect(session.command("AUTH LOGIN"), 334)
                try await session.expect(session.command(Data(username.utf8).base64EncodedString(), secret: true), 334)
                reply = try await session.command(Data(password.utf8).base64EncodedString(), secret: true)
            } else {
                throw MailError.signInFailed("The outgoing server does not accept a password.")
            }
        case .oauth2(let token):
            guard methods.contains("XOAUTH2") else { throw MailError.signInFailed("The outgoing server does not offer OAuth sign-in.") }
            let payload = Data("user=\(username)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
            var answer = try await session.command("AUTH XOAUTH2 " + payload, secret: true)
            // A failure comes as 334 with details; an empty line ends the exchange.
            if answer.code == 334 { answer = try await session.command("", secret: true) }
            reply = answer
        }
        guard reply.code == 235 else { throw MailError.signInFailed("Check the sign-in details and the account's SMTP access.") }
    }

    /// Only plain addresses: no brackets, spaces, or line breaks that could change the command.
    static func isSafeAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && address.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0 != "<" && $0 != ">" && $0 != "\u{7F}" }
    }

    /// CRLF line ends, a leading dot doubled on each line, and the closing "." line.
    static func dotStuffed(_ message: Data) -> Data {
        var out = Data()
        out.reserveCapacity(message.count + 64)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in message {
            if byte == Byte.lf && previous != Byte.cr { out.append(Byte.cr) }
            if atLineStart && byte == Byte.dot { out.append(Byte.dot) }
            out.append(byte)
            atLineStart = byte == Byte.lf
            previous = byte
        }
        if !atLineStart { out.append(contentsOf: [Byte.cr, Byte.lf]) }
        out.append(contentsOf: [Byte.dot, Byte.cr, Byte.lf])
        return out
    }
}

/// A reply such as "250-SIZE 1000" … "250 OK": the code and the text of every line.
public struct SMTPReply: Equatable, Sendable {
    public let code: Int
    public let lines: [String]
    public var text: String { lines.joined(separator: " ") }
}

/// Reads SMTP replies line by line from a transport.
final class SMTPSession: @unchecked Sendable {
    let transport: MailTransport
    let timeout: TimeInterval
    private var buffer: [UInt8] = []
    private(set) var extensions: [String: String] = [:]

    init(transport: MailTransport, timeout: TimeInterval) { self.transport = transport; self.timeout = timeout }

    func close() { transport.close() }

    func hello() async throws {
        let reply = try await command("EHLO [127.0.0.1]")
        try expect(reply, 250)
        extensions = [:]
        for line in reply.lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let name = parts.first else { continue }
            extensions[name.uppercased()] = parts.count > 1 ? String(parts[1]) : ""
        }
    }

    func startTLS() async throws {
        try await transport.startTLS()
        // Bytes sent before TLS are dropped, so they cannot pose as replies.
        buffer = []
    }

    /// `secret` marks a line that must not appear in an error, such as a password.
    func command(_ line: String, secret: Bool = false) async throws -> SMTPReply {
        guard !line.contains("\r"), !line.contains("\n") else { throw MailError.unexpected(secret ? "a line break in a sign-in value" : "a line break in a command") }
        try await write(Data((line + "\r\n").utf8))
        return try await read()
    }

    func write(_ data: Data) async throws { try await transport.write(data) }

    func expect(_ reply: SMTPReply, _ code: Int) throws {
        guard reply.code == code else { throw MailError.smtp(code: reply.code, text: reply.text) }
    }

    func read() async throws -> SMTPReply {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else { throw MailError.unexpected("an unreadable SMTP reply") }
            let rest = line.dropFirst(3)
            lines.append(String(rest.dropFirst()))
            if rest.first != "-" { return SMTPReply(code: code, lines: lines) }
            guard lines.count < 200 else { throw MailError.unexpected("an SMTP reply with too many lines") }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let lf = buffer.firstIndex(of: Byte.lf) {
                var end = lf
                if end > 0, buffer[end - 1] == Byte.cr { end -= 1 }
                let line = String(decoding: buffer[0..<end], as: UTF8.self)
                buffer.removeSubrange(0...lf)
                return line
            }
            guard buffer.count < 64 * 1024 else { throw MailError.unexpected("an SMTP line that never ends") }
            buffer.append(contentsOf: try await transport.read(timeout: timeout))
        }
    }
}
