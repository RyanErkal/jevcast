import Foundation
@testable import LauncherCore

/// An in-memory SMTP server for tests. Records each delivered message and its envelope.
final class FakeSMTPServer: @unchecked Sendable {
    struct Delivery { let from: String; let recipients: [String]; let data: Data }
    let lock = NSLock()
    var password = "app-password"
    var extensions = ["AUTH PLAIN LOGIN", "8BITMIME", "SIZE 35882577"]
    var startTLS = false
    private(set) var deliveries: [Delivery] = []
    /// Addresses the server refuses at RCPT.
    var refused: Set<String> = []

    func add(_ delivery: Delivery) { lock.withLock { deliveries.append(delivery) } }
    var delivered: [Delivery] { lock.withLock { deliveries } }

    func connect() -> MailTransport { FakeSMTPTransport(server: self) }
}

final class FakeSMTPTransport: MailTransport, @unchecked Sendable {
    private let server: FakeSMTPServer
    private let lock = NSLock()
    private var input: [UInt8] = []
    private var output: [UInt8] = Array("220 fake.example ESMTP\r\n".utf8)
    private var reader: CheckedContinuation<Data, Error>?
    private var inData = false
    private var authLogin = 0
    private var from = ""
    private var recipients: [String] = []
    private var signedIn = false

    init(server: FakeSMTPServer) { self.server = server }

    func write(_ data: Data) async throws {
        let wake: (CheckedContinuation<Data, Error>, Data)? = lock.withLock {
            input += data
            process()
            guard let reader, !output.isEmpty else { return nil }
            self.reader = nil
            defer { output = [] }
            return (reader, Data(output))
        }
        if let (reader, data) = wake { reader.resume(returning: data) }
    }

    func read(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Data? = lock.withLock {
                if !output.isEmpty { defer { output = [] }; return Data(output) }
                reader = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func startTLS() async throws {}
    func close() {}

    private func reply(_ text: String) { output += Array((text + "\r\n").utf8) }

    private func process() {
        while true {
            if inData {
                guard let end = findEnd() else { return }
                let body = Data(input[0..<end])
                input.removeFirst(end + 5)
                inData = false
                server.add(.init(from: from, recipients: recipients, data: body))
                reply("250 2.0.0 queued")
                continue
            }
            guard let lf = input.firstIndex(of: 0x0A) else { return }
            let line = String(decoding: input[0..<lf], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            input.removeSubrange(0...lf)
            handle(line)
        }
    }

    /// The "\r\n.\r\n" that ends DATA.
    private func findEnd() -> Int? {
        let marker: [UInt8] = [0x0D, 0x0A, 0x2E, 0x0D, 0x0A]
        guard input.count >= 5 else { return nil }
        for index in 0...(input.count - 5) where Array(input[index..<index + 5]) == marker { return index }
        return nil
    }

    private func handle(_ line: String) {
        if authLogin == 1 { authLogin = 2; reply("334 UGFzc3dvcmQ6"); return }
        if authLogin == 2 {
            authLogin = 0
            let password = Data(base64Encoded: line).map { String(decoding: $0, as: UTF8.self) }
            signedIn = password == server.password
            reply(signedIn ? "235 2.7.0 ok" : "535 5.7.8 bad credentials")
            return
        }
        let upper = line.uppercased()
        if upper.hasPrefix("EHLO") {
            let lines = ["fake.example"] + server.extensions + (server.startTLS ? ["STARTTLS"] : [])
            for (index, text) in lines.enumerated() { reply("250" + (index == lines.count - 1 ? " " : "-") + text) }
        } else if upper == "STARTTLS" {
            reply("220 go ahead")
        } else if upper.hasPrefix("AUTH PLAIN ") {
            let payload = Data(base64Encoded: String(line.dropFirst(11))).map { String(decoding: $0, as: UTF8.self) } ?? ""
            signedIn = payload.split(separator: "\u{0}", omittingEmptySubsequences: false).last.map(String.init) == server.password
            reply(signedIn ? "235 2.7.0 ok" : "535 5.7.8 bad credentials")
        } else if upper == "AUTH LOGIN" {
            authLogin = 1
            reply("334 VXNlcm5hbWU6")
        } else if upper.hasPrefix("MAIL FROM:") {
            guard signedIn else { reply("530 sign in first"); return }
            from = String(line.dropFirst(10)).components(separatedBy: " ").first ?? ""
            recipients = []
            reply("250 ok")
        } else if upper.hasPrefix("RCPT TO:") {
            let address = String(line.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            if server.refused.contains(address) { reply("550 5.1.1 no such user") } else { recipients.append(address); reply("250 ok") }
        } else if upper == "DATA" {
            inData = true
            reply("354 go ahead")
        } else if upper == "QUIT" {
            reply("221 bye")
        } else {
            reply("500 unknown")
        }
    }
}
