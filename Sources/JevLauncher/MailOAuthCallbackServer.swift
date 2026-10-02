import Foundation
import LauncherCore
import Network

/// A single OAuth callback on loopback only. It never listens on a LAN or tailnet address.
final class MailOAuthCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "jevcast.mail.oauth.callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var starting: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var expiry: DispatchWorkItem?
    private var connections: [NWConnection] = []
    private var redirect: URL?
    private let authorization: MailOAuthAuthorization

    init(authorization: MailOAuthAuthorization) throws {
        try MailIOPolicy.requireOnline()
        self.authorization = authorization
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(provider: MailOAuthProvider) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready in
                let existing = lock.withLock { () -> Result<URL, Error>? in
                    if let result { return result }
                    starting = ready; return nil
                }
                if let existing { ready.resume(with: existing); return }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port else { return }
                        let host = provider == .google ? "127.0.0.1" : "localhost"
                        let url = URL(string: "http://\(host):\(port.rawValue)/oauth/callback")!
                        self.redirect = url
                        let expiry = DispatchWorkItem { [weak self] in self?.finish(.failure(MailOAuthError.expired)) }
                        self.expiry = expiry; self.queue.asyncAfter(deadline: .now() + 300, execute: expiry)
                        self.completeStart(.success(url))
                    case .failed:
                        self.finish(.failure(MailOAuthError.invalidCallback))
                    case .cancelled:
                        self.finish(.failure(MailOAuthError.cancelled))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.connections.count < 8 else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: self.queue)
                    self.receive(connection, buffer: Data())
                }
                listener.start(queue: queue)
            }
        } onCancel: { self.cancel() }
    }

    private func completeStart(_ value: Result<URL, Error>) {
        let ready = lock.withLock { let ready = starting; starting = nil; return ready }
        ready?.resume(with: value)
    }

    func wait() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting in
                let existing = lock.withLock { () -> Result<URL, Error>? in
                    if let result { return result }
                    continuation = waiting; return nil
                }
                if let existing { waiting.resume(with: existing) }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { finish(.failure(MailOAuthError.cancelled)) }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let buffer = buffer + (data ?? Data())
            guard buffer.count <= 16_384, error == nil else { self.respond(connection, status: "400 Bad Request", text: "Invalid sign-in response."); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                if complete { self.respond(connection, status: "400 Bad Request", text: "Incomplete response.") } else { self.receive(connection, buffer: buffer) }
                return
            }
            guard let redirect = self.redirect,
                  let callback = Self.callback(request: buffer, redirect: redirect) else {
                self.respond(connection, status: "400 Bad Request", text: "Invalid sign-in response."); return
            }
            do {
                _ = try self.authorization.code(from: callback, redirect: redirect)
                self.respond(connection, status: "200 OK", text: "Sign-in received. Return to Jevcast.")
                self.finish(.success(callback))
            } catch MailOAuthError.cancelled {
                self.respond(connection, status: "200 OK", text: "Sign-in cancelled. Return to Jevcast.")
                self.finish(.failure(MailOAuthError.cancelled))
            } catch { self.respond(connection, status: "400 Bad Request", text: "This response does not match the sign-in request.") }
        }
    }

    static func callback(request: Data, redirect: URL) -> URL? {
        guard let text = String(data: request, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1", parts[1].hasPrefix("/oauth/callback?"),
              !parts[1].hasPrefix("//") else { return nil }
        let host = text.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("host:") }
        guard host.count == 1, host[0].dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() == "\(redirect.host ?? ""):\(redirect.port ?? 0)" else { return nil }
        return URL(string: String(parts[1]), relativeTo: redirect)?.absoluteURL
    }

    private func respond(_ connection: NWConnection, status: String, text: String) {
        let body = Data(text.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.queue.async { self?.connections.removeAll { $0 === connection } }
        })
    }

    private func finish(_ value: Result<URL, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard result == nil else { return nil }
            result = value; defer { continuation = nil }; return continuation
        }
        waiting?.resume(with: value)
        completeStart(value)
        queue.async { [weak self] in self?.expiry?.cancel(); self?.listener.cancel() }
    }
    deinit { listener.cancel(); expiry?.cancel(); connections.forEach { $0.cancel() } }
}
