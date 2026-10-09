import AppKit
import LauncherCore

private let mailOAuthKeychainUnavailableMessage = "The saved mail sign-in could not be accessed. Unlock Keychain and try again."

enum MailOAuthSetup {
    static func client(_ provider: MailOAuthProvider) throws -> MailOAuthClient {
        try MailOAuthClient(provider: provider, clientID: UserDefaults.standard.string(forKey: key(provider)) ?? "")
    }
    static func key(_ provider: MailOAuthProvider) -> String { "mailOAuthClientID." + provider.rawValue }
    static let googleSecretKey = "mail-oauth-google-client-secret"
    static func provider(_ account: NativeMailAccount) throws -> MailOAuthProvider {
        switch account.provider {
        case .gmail: return .google
        case .outlook: return .microsoft
        default: throw MailOAuthError.invalidClient
        }
    }
}

/// Reads and refreshes tokens only in the Keychain. Concurrent connections share one refresh.
actor MailOAuthCredentials {
    static let shared = MailOAuthCredentials()
    private struct Refresh {
        let id: UUID
        let task: Task<MailOAuthToken, Error>
    }
    private var refreshes: [String: Refresh] = [:]
    private let read: @Sendable (String) throws -> String?
    private let persist: @Sendable (MailOAuthToken, String) throws -> Void
    private let client: @Sendable (MailOAuthProvider) throws -> MailOAuthClient
    private let secret: @Sendable () throws -> String?
    private let http: MailOAuthHTTP
    static func key(_ id: String) -> String { "mail-oauth-" + id }

    init(read: @escaping @Sendable (String) throws -> String? = { id in try MailIOPolicy.requireOnline(); return try KeychainStore.read(account: key(id)) },
         persist: @escaping @Sendable (MailOAuthToken, String) throws -> Void = { try save($0, accountID: $1) },
         client: @escaping @Sendable (MailOAuthProvider) throws -> MailOAuthClient = { try MailOAuthSetup.client($0) },
         secret: @escaping @Sendable () throws -> String? = { try MailIOPolicy.requireOnline(); return try KeychainStore.read(account: MailOAuthSetup.googleSecretKey) },
         http: MailOAuthHTTP = MailOAuthHTTP()) {
        self.read = read; self.persist = persist; self.client = client; self.secret = secret; self.http = http
    }

    func credential(for account: NativeMailAccount) async throws -> MailCredential {
        do { return try await readCredential(for: account) }
        catch let error as MailOAuthError {
            if error == .temporarilyUnavailable { throw error }
            throw MailError.signInFailed(error.localizedDescription)
        } catch is KeychainStoreError {
            throw MailError.notFound(mailOAuthKeychainUnavailableMessage)
        }
    }

    func cancelRefresh(_ id: String) {
        refreshes.removeValue(forKey: id)?.task.cancel()
    }

    private func readCredential(for account: NativeMailAccount) async throws -> MailCredential {
        if let refresh = refreshes[account.id] { return .oauth2(accessToken: try await refresh.task.value.accessToken) }
        let provider = try MailOAuthSetup.provider(account), client = try self.client(provider)
        guard let stored = try read(account.id),
              let data = stored.data(using: .utf8), let token = try? JSONDecoder().decode(MailOAuthToken.self, from: data),
              token.clientID == client.clientID else { throw MailOAuthError.signInRequired }
        guard token.needsRefresh else { return .oauth2(accessToken: token.accessToken) }
        let refreshID = UUID()
        let task = Task { () throws -> MailOAuthToken in
            let secret = provider == .google ? try self.secret() : nil
            let fresh = try await self.http.refresh(token, client: client, secret: secret)
            try Task.checkCancellation()
            try self.persist(fresh, account.id)
            return fresh
        }
        refreshes[account.id] = Refresh(id: refreshID, task: task)
        defer { if refreshes[account.id]?.id == refreshID { refreshes[account.id] = nil } }
        return .oauth2(accessToken: try await task.value.accessToken)
    }

    static func save(_ token: MailOAuthToken, accountID: String) throws {
        let data = try JSONEncoder().encode(token)
        do {
            try KeychainStore.save(String(decoding: data, as: UTF8.self), account: key(accountID))
        } catch is KeychainStoreError {
            throw MailError.notFound(mailOAuthKeychainUnavailableMessage)
        }
    }
}

@MainActor
enum MailOAuthSignIn {
    static func authenticate(_ account: NativeMailAccount) async throws -> MailOAuthToken {
        try MailIOPolicy.requireOnline()
        let provider = try MailOAuthSetup.provider(account), client = try MailOAuthSetup.client(provider)
        let authorization = try MailOAuthAuthorization()
        let server = try MailOAuthCallbackServer(authorization: authorization)
        defer { server.cancel() }
        let redirect = try await server.start(provider: provider)
        try Task.checkCancellation()
        let url = try authorization.url(client: client, redirect: redirect, email: account.email)
        guard NSWorkspace.shared.open(url) else { throw MailOAuthError.cancelled }
        let callback = try await server.wait()
        let code = try authorization.code(from: callback, redirect: redirect)
        let secret: String?
        do {
            secret = provider == .google ? try KeychainStore.read(account: MailOAuthSetup.googleSecretKey) : nil
        } catch is KeychainStoreError {
            throw MailError.notFound(mailOAuthKeychainUnavailableMessage)
        }
        return try await MailOAuthHTTP().exchange(code: code, authorization: authorization, redirect: redirect, client: client, secret: secret)
    }
}
