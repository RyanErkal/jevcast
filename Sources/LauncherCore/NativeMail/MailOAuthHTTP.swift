import Foundation

public struct MailOAuthHTTP: Sendable {
    public typealias Request = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let request: Request
    public init(request: @escaping Request = MailOAuthHTTP.network) { self.request = request }

    public static let network: Request = { request in
        try MailIOPolicy.requireOnline()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: OAuthNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MailOAuthError.invalidToken }
        return (data, http)
    }

    public func exchange(code: String, authorization: MailOAuthAuthorization, redirect: URL,
                         client: MailOAuthClient, secret: String? = nil, scopes: [String]? = nil) async throws -> MailOAuthToken {
        try MailOAuthAuthorization.validateRedirect(redirect)
        return try await token(client: client, secret: secret, values: ["grant_type": "authorization_code", "code": code,
            "code_verifier": authorization.verifier, "redirect_uri": redirect.absoluteString], previous: nil, scopes: scopes)
    }

    public func refresh(_ previous: MailOAuthToken, client: MailOAuthClient, secret: String? = nil, scopes: [String]? = nil) async throws -> MailOAuthToken {
        guard previous.clientID == client.clientID else { throw MailOAuthError.signInRequired }
        return try await token(client: client, secret: secret, values: ["grant_type": "refresh_token", "refresh_token": previous.refreshToken], previous: previous, scopes: scopes)
    }

    private func token(client: MailOAuthClient, secret: String?, values: [String: String], previous: MailOAuthToken?, scopes: [String]?) async throws -> MailOAuthToken {
        var form = values; form["client_id"] = client.clientID
        if client.provider == .google, let secret, !secret.isEmpty { form["client_secret"] = secret }
        if client.provider == .microsoft { form["scope"] = client.provider.scopes.joined(separator: " ") }
        var request = URLRequest(url: client.provider.tokenURL)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(form).utf8)
        let (data, response) = try await self.request(request)
        guard response.url == client.provider.tokenURL else { throw MailOAuthError.invalidToken }
        if (300...399).contains(response.statusCode) { throw MailOAuthError.refused }
        if response.statusCode == 408 || response.statusCode == 429 || (500...599).contains(response.statusCode) {
            throw MailOAuthError.temporarilyUnavailable
        }
        guard data.count <= 128 * 1024 else { throw MailOAuthError.invalidToken }
        guard response.statusCode == 200 else {
            struct ErrorPayload: Decodable { let error: String? }
            let code = (try? JSONDecoder().decode(ErrorPayload.self, from: data))?.error?.lowercased()
            switch code {
            case "server_error", "temporarily_unavailable":
                throw MailOAuthError.temporarilyUnavailable
            case "invalid_grant", "access_denied", "login_required", "interaction_required":
                throw MailOAuthError.signInRequired
            case "invalid_client":
                throw MailOAuthError.invalidClient
            case "invalid_request", "unsupported_grant_type", "unauthorized_client", "invalid_scope":
                throw MailOAuthError.refused
            default:
                throw response.statusCode == 400 || response.statusCode == 401 ? MailOAuthError.signInRequired : MailOAuthError.refused
            }
        }
        struct Payload: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int; let token_type: String; let scope: String? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
              !payload.access_token.isEmpty, payload.access_token.count < 32_768,
              payload.access_token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }), (1...604_800).contains(payload.expires_in),
              let refresh = payload.refresh_token ?? previous?.refreshToken, !refresh.isEmpty,
              refresh.count < 32_768, refresh.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }) else { throw MailOAuthError.invalidToken }
        if let scope = payload.scope {
            let granted = Set(scope.split(separator: " ").map(String.init))
            guard Set((scopes ?? client.provider.scopes).filter { $0 != "offline_access" }).isSubset(of: granted) else { throw MailOAuthError.invalidToken }
        }
        return .init(accessToken: payload.access_token, refreshToken: refresh,
                     expiresAt: Date().addingTimeInterval(TimeInterval(payload.expires_in)), clientID: client.clientID)
    }

    static func form(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return values.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }
}

private final class OAuthNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
