import Foundation

/// A byte stream to a mail server. Tests use a scripted fake; the app uses `StreamTaskTransport`.
public protocol MailTransport: AnyObject, Sendable {
    func write(_ data: Data) async throws
    /// At least one byte. Throws when the server closes the stream or `timeout` passes.
    func read(timeout: TimeInterval) async throws -> Data
    /// Starts TLS on the open connection, for STARTTLS.
    func startTLS() async throws
    func close()
}

/// How a server is reached. Every account uses TLS; there is no plain-text option.
public enum MailSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte, such as IMAP on 993 and SMTP on 465.
    case tls
    /// A plain connection that the client moves to TLS before it signs in, such as SMTP on 587.
    case startTLS
}

public enum MailTransportError: Error, LocalizedError, Equatable {
    case closed
    case timedOut
    case connectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .closed: return "The mail server closed the connection."
        case .timedOut: return "The mail server did not answer in time."
        case .connectFailed(let text): return text
        }
    }
}

/// A TCP connection through `URLSessionStreamTask`, which can start TLS on an open connection,
/// as STARTTLS needs, and checks the server's certificate as Safari does.
public final class StreamTaskTransport: MailTransport, @unchecked Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration)
    }()
    private let task: URLSessionStreamTask
    private let host: String

    public init(host: String, port: Int, tls: Bool) {
        self.host = host
        task = Self.session.streamTask(withHostName: host, port: port)
        task.resume()
        if tls { task.startSecureConnection() }
    }

    public func write(_ data: Data) async throws {
        do { try await task.write(data, timeout: 60) } catch { throw translate(error) }
    }

    public func read(timeout: TimeInterval) async throws -> Data {
        let result: (Data?, Bool)
        do { result = try await task.readData(ofMinLength: 1, maxLength: 1 << 20, timeout: timeout) } catch { throw translate(error) }
        if let data = result.0, !data.isEmpty { return data }
        throw MailTransportError.closed
    }

    public func startTLS() async throws { task.startSecureConnection() }

    public func close() { task.cancel() }

    private func translate(_ error: Error) -> Error {
        guard let url = error as? URLError else { return error }
        switch url.code {
        case .timedOut: return MailTransportError.timedOut
        case .cannotFindHost, .dnsLookupFailed: return MailTransportError.connectFailed("Could not find the mail server \(host).")
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return MailTransportError.connectFailed("Could not connect to \(host). Check the network.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return MailTransportError.connectFailed("The secure connection to \(host) failed. Its certificate was not accepted.")
        case .cancelled: return CancellationError()
        default: return MailTransportError.connectFailed("The connection to \(host) failed: \(url.localizedDescription)")
        }
    }
}
