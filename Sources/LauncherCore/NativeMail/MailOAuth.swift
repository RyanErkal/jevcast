import CryptoKit
import Foundation
import Security

public enum MailOAuthProvider: String, Codable, CaseIterable, Sendable {
    case google, microsoft
    public var title: String { self == .google ? "Google" : "Microsoft" }
    public var authorizationURL: URL {
        URL(string: self == .google ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
    }
    public var tokenURL: URL {
        URL(string: self == .google ? "https://oauth2.googleapis.com/token" : "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
    }
    public var scopes: [String] {
        self == .google ? ["https://mail.google.com/"] : ["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send", "offline_access"]
    }
    public var setupURL: URL {
        URL(string: self == .google ? "https://console.cloud.google.com/auth/clients" : "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!
    }
    public var instructions: String {
        self == .google
            ? "Create an OAuth client with type Desktop app. Configure the consent screen and add your address as a test user while the app is in Testing. Copy the client ID here. A desktop client secret is optional and stays in the Keychain."
            : "Register an app for organizational and personal Microsoft accounts. Add Mobile and desktop applications with redirect URI http://localhost/oauth/callback. Add delegated IMAP.AccessAsUser.All and SMTP.Send permissions for Office 365 Exchange Online. Enable public client flows. Copy the Application (client) ID here. Do not create a client secret."
    }
}

public struct MailOAuthClient: Codable, Equatable, Sendable {
    public let provider: MailOAuthProvider
    public let clientID: String
    public init(provider: MailOAuthProvider, clientID: String) throws {
        let value = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count < 512, !value.contains(where: \.isWhitespace),
              provider != .google || value.hasSuffix(".apps.googleusercontent.com"),
              provider != .microsoft || UUID(uuidString: value) != nil else {
            throw MailOAuthError.invalidClient
        }
        self.provider = provider; self.clientID = value
    }
}

public enum MailOAuthError: Error, LocalizedError, Equatable {
    case invalidClient, invalidCallback, cancelled, expired, invalidToken, signInRequired, refused, temporarilyUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidClient: return "Enter the provider's OAuth app client ID in Settings › Mail."
        case .invalidCallback: return "The sign-in response did not match this request. Nothing was connected."
        case .cancelled: return "Sign-in was cancelled. Nothing was connected."
        case .expired: return "Sign-in took too long. Start it again."
        case .invalidToken: return "The provider did not return a usable mail token. Check the app permissions and sign in again."
        case .signInRequired: return "This mail account needs you to sign in again."
        case .refused: return "The provider refused sign-in. Check the OAuth app setup and account permissions."
        case .temporarilyUnavailable: return "The mail provider is temporarily unavailable. Try again shortly."
        }
    }
}

public struct MailOAuthAuthorization: Sendable {
    public let verifier: String
    public let state: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public init() throws {
        verifier = try Self.random(); state = try Self.random()
    }
    public init(verifier: String, state: String) { self.verifier = verifier; self.state = state }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MailOAuthError.invalidCallback }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public func url(client: MailOAuthClient, redirect: URL, email: String, scopes: [String]? = nil) throws -> URL {
        try Self.validateRedirect(redirect)
        var components = URLComponents(url: client.provider.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: client.clientID), .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: (scopes ?? client.provider.scopes).joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "login_hint", value: email)
        ]
        if client.provider == .google { components.queryItems! += [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")] }
        return components.url!
    }

    public func code(from callback: URL, redirect: URL) throws -> String {
        try Self.validateRedirect(redirect)
        guard callback.scheme == redirect.scheme, callback.host == redirect.host, callback.port == redirect.port,
              callback.path == redirect.path, callback.fragment == nil, callback.user == nil, callback.password == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else { throw MailOAuthError.invalidCallback }
        let names = items.map(\.name)
        guard Set(names).count == names.count, items.first(where: { $0.name == "state" })?.value == state else { throw MailOAuthError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw MailOAuthError.cancelled }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count <= 8192 else { throw MailOAuthError.invalidCallback }
        return code
    }

    public static func validateRedirect(_ url: URL) throws {
        guard url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              url.port.map({ (1024...65535).contains($0) }) == true, url.path == "/oauth/callback",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw MailOAuthError.invalidCallback }
    }
}

public struct MailOAuthToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let clientID: String
    public var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 90 }
    public init(accessToken: String, refreshToken: String, expiresAt: Date, clientID: String) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.clientID = clientID
    }
}
