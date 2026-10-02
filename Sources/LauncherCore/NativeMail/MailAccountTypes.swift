import Foundation

/// A mail server's address and how the connection is secured.
public struct MailServer: Codable, Sendable, Equatable, Hashable {
    public var host: String
    public var port: Int
    public var security: MailSecurity
    public init(host: String, port: Int, security: MailSecurity) { self.host = host; self.port = port; self.security = security }

    public func validated() throws -> MailServer {
        guard !host.isEmpty, host.count <= 253, (1...65535).contains(port),
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-:".unicodeScalars.contains($0) }),
              !host.hasPrefix("."), !host.hasSuffix(".") else {
            throw MailError.notFound("Enter a mail server host and a port from 1 to 65535. Use TLS or STARTTLS.")
        }
        return self
    }
}

/// What signs in to a server. Values live only in memory and the Keychain; never in files or logs.
public enum MailCredential: Sendable, Equatable {
    /// A password, which for Yahoo, iCloud, and Gmail is an app password.
    case password(String)
    /// An OAuth 2 access token for XOAUTH2.
    case oauth2(accessToken: String)
}

/// Errors a person can act on. Each text says what failed and, when it helps, what to do.
public enum MailError: Error, LocalizedError, Equatable {
    case commandFailed(command: String, status: IMAPStatus, text: String)
    case signInFailed(String)
    case noSecureConnection(host: String)
    case serverClosed(String)
    case uidValidityChanged(mailbox: String)
    case unexpected(String)
    case smtp(code: Int, text: String)
    case notFound(String)
    case deliveryUncertain
    /// The server has no IDLE, so new mail is found by asking every few minutes.
    case idleUnsupported

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, text):
            return "The mail server answered \(status.rawValue) to \(command)" + (text.isEmpty ? "." : ": \(text)")
        case .signInFailed(let text):
            return "The mail account could not sign in" + (text.isEmpty ? "." : ": \(text)") + " Check Settings › Mail. Password accounts can require an app password."
        case .noSecureConnection(let host):
            return "\(host) does not offer a secure connection, so Jevcast did not sign in."
        case .serverClosed(let text):
            return "The mail server ended the session" + (text.isEmpty ? "." : ": \(text)")
        case .uidValidityChanged(let mailbox):
            return "The server renumbered \(mailbox). Jevcast reads it again."
        case .unexpected(let text):
            return "The mail server sent something Jevcast did not expect: \(text)."
        case let .smtp(code, text):
            return "The outgoing mail server answered \(code)" + (text.isEmpty ? "." : ": \(text)")
        case .notFound(let text):
            return text
        case .deliveryUncertain:
            return "The server may have accepted this message. Check Sent before you send it again."
        case .idleUnsupported:
            return "The mail server cannot report new mail as it arrives."
        }
    }

    /// True when a retry on a new connection may work.
    public var isTransient: Bool {
        switch self {
        case .serverClosed: return true
        default: return false
        }
    }
}
