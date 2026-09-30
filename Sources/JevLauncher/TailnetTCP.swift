import Foundation
import LauncherCore
import Network
import Security

/// One request to a device on the tailnet, over TCP or TLS.
struct TCPRequest: Sendable {
    enum Security: Equatable, Sendable {
        case plain
        /// TLS, with the name the certificate must carry. The connection still goes to the IP address,
        /// so no DNS lookup can send it elsewhere. Without a name the certificate cannot match.
        case tls(name: String?)
    }
    let ip: String
    let port: Int
    let security: Security
    let bytes: Data
    let limit: Int
    let deadline: TimeInterval
}

/// What one exchange got back.
enum TCPOutcome: Equatable, Sendable {
    /// Nothing listens, a firewall dropped the connection, or the time ran out before any answer.
    case nothing
    /// The server took the request and closed the connection without a byte, as a TLS-only port does.
    case closedEmpty
    /// A TLS server answered, but its certificate was not accepted.
    case untrusted
    case answered(Data)
}

/// Sends one request and reads the answer until the server closes the connection, the answer is whole,
/// `limit` bytes arrive, or `deadline` seconds pass. The connection itself gets at most 2 seconds, so a
/// firewall that drops it never holds a slow answer's longer deadline. Network.framework, so App Transport
/// Security does not apply, no proxy is used, and TLS checks the certificate as Safari does.
enum TailnetTCP {
    typealias Send = @Sendable (TCPRequest) async -> TCPOutcome

    static let send: Send = { request in
        guard TailnetAddress.isTailnet(request.ip), let port = NWEndpoint.Port(rawValue: UInt16(clamping: request.port)) else { return .nothing }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 2
        var tls: NWProtocolTLS.Options?
        if case .tls(let name) = request.security {
            let options = NWProtocolTLS.Options()
            if let name { sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, name) }
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(request.ip), port: port, using: parameters)
        return await Exchange(connection: connection, request: request.bytes, limit: request.limit).run(deadline: request.deadline)
    }

    /// TLS failures that mean the server answered with a certificate this Mac does not accept.
    static let certificateErrors: Set<OSStatus> = [errSSLXCertChainInvalid, errSSLBadCert, errSSLUnknownRootCert, errSSLNoRootCert,
                                                   errSSLCertExpired, errSSLCertNotYetValid, errSSLHostNameMismatch, errSSLPeerBadCert,
                                                   errSSLPeerCertUnknown, errSecNotTrusted, errSecCertificateExpired]
}

/// One connection's state. Every callback runs on `queue`, so the state needs no lock.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let limit: Int
    private let queue = DispatchQueue(label: "Jevcast.tailnet.tcp")
    private var data = Data()
    private var sent = false
    private var continuation: CheckedContinuation<TCPOutcome, Never>?

    init(connection: NWConnection, request: Data, limit: Int) {
        self.connection = connection; self.request = request; self.limit = limit
    }

    func run(deadline: TimeInterval) async -> TCPOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready: send()
                    // Waiting means refused or unreachable; the connection would only retry.
                    case .waiting(let error), .failed(let error):
                        if case .tls(let status) = error, TailnetTCP.certificateErrors.contains(status) { finish(.untrusted) } else { finish(ended) }
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + deadline) { [self] in finish(data.isEmpty ? .nothing : .answered(data)) }
            }
        }
    }

    private func send() {
        connection.send(content: request, completion: .contentProcessed { [self] error in
            guard error == nil else { finish(.nothing); return }
            sent = true
            receive()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] content, _, isComplete, error in
            if let content { data.append(content) }
            if data.count >= limit || PlainHTTP.parse(data)?.complete == true { finish(.answered(data)); return }
            if isComplete || error != nil { finish(ended); return }
            receive()
        }
    }

    /// How the exchange ended when the server closed or failed the connection.
    private var ended: TCPOutcome { data.isEmpty ? (sent ? .closedEmpty : .nothing) : .answered(data) }

    private func finish(_ outcome: TCPOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: outcome)
    }
}
