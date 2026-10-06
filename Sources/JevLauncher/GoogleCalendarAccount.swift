import AppKit
import LauncherCore

/// Calendar has its own token and opt-in. A Mail sign-in never grants Calendar access.
@MainActor
final class GoogleCalendarAccount: ObservableObject {
    static let shared = GoogleCalendarAccount()
    nonisolated static let tokenKey = "calendar-google-oauth-token"
    nonisolated static let clientKey = "calendarGoogleClientID"
    nonisolated static let secretKey = "calendar-google-client-secret"
    @Published private(set) var connected: Bool
    @Published private(set) var calendars: [GoogleCalendarInfo] = []
    @Published private(set) var enabledIDs: Set<String>
    private let defaults: UserDefaults
    private let api: GoogleCalendarAPI
    private let http: MailOAuthHTTP
    private let readToken: () throws -> MailOAuthToken?
    private let saveToken: (MailOAuthToken) throws -> Void
    private let deleteToken: () throws -> Void
    private let readSecret: () throws -> String?
    private let writeSecret: (String?) throws -> Void
    private let authenticate: @MainActor (MailOAuthClient, String?) async throws -> MailOAuthToken
    private var refresh: Task<MailOAuthToken, Error>?
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, api: GoogleCalendarAPI = .init(), http: MailOAuthHTTP = .init(),
         readToken: @escaping () throws -> MailOAuthToken? = {
             try GoogleCalendarAPI.requireOnline()
             guard let text = try KeychainStore.read(account: tokenKey), let data = text.data(using: .utf8) else { return nil }
             return try JSONDecoder().decode(MailOAuthToken.self, from: data)
         }, saveToken: @escaping (MailOAuthToken) throws -> Void = {
             try KeychainStore.save(String(decoding: JSONEncoder().encode($0), as: UTF8.self), account: tokenKey)
         }, deleteToken: @escaping () throws -> Void = { try KeychainStore.delete(account: tokenKey) },
         readSecret: @escaping () throws -> String? = {
             try GoogleCalendarAPI.requireOnline()
             if let secret = try KeychainStore.read(account: secretKey) { return secret }
             let defaults = UserDefaults.standard
             let mailID = defaults.string(forKey: MailOAuthSetup.key(.google))
             let calendarID = defaults.string(forKey: clientKey) ?? mailID
             guard let mailID, calendarID == mailID else { return nil }
             return try KeychainStore.read(account: MailOAuthSetup.googleSecretKey)
         }, writeSecret: @escaping (String?) throws -> Void = {
             if let secret = $0 { try KeychainStore.save(secret, account: secretKey) }
             else { try KeychainStore.delete(account: secretKey) }
         }, authenticate: @escaping @MainActor (MailOAuthClient, String?) async throws -> MailOAuthToken = { client, secret in
             try await browserToken(client: client, secret: secret)
         }) {
        self.defaults = defaults; self.api = api; self.http = http
        self.readToken = readToken; self.saveToken = saveToken; self.deleteToken = deleteToken; self.readSecret = readSecret
        self.writeSecret = writeSecret; self.authenticate = authenticate
        connected = defaults.bool(forKey: "calendarGoogleConnected")
        enabledIDs = Set(defaults.stringArray(forKey: "calendarGoogleEnabledIDs") ?? [])
    }

    var clientID: String { defaults.string(forKey: Self.clientKey) ?? defaults.string(forKey: MailOAuthSetup.key(.google)) ?? "" }
    var label: String { calendars.first(where: { $0.primary == true })?.summary ?? "Google Calendar" }

    func signIn(clientID: String, secret: String) async throws {
        let current = generation
        let client = try MailOAuthClient(provider: .google, clientID: clientID)
        let previousID = self.clientID
        let clientSecret = secret.isEmpty && previousID == client.clientID ? try readSecret() : (secret.isEmpty ? nil : secret)
        let token = try await authenticate(client, clientSecret)
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        // Check Calendar API access before replacing a working connection.
        let list = try await api.calendars(token: token.accessToken)
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        if let clientSecret { try writeSecret(clientSecret) }
        else if previousID != client.clientID { try writeSecret(nil) }
        try saveToken(token)
        defaults.set(client.clientID, forKey: Self.clientKey)
        defaults.set(true, forKey: "calendarGoogleConnected")
        defaults.set(CalendarPage.Source.google.rawValue, forKey: "calendarSource")
        refresh?.cancel(); refresh = nil; generation = UUID()
        connected = true
        defaults.removeObject(forKey: "calendarGoogleEnabledIDs")
        acceptCalendars(list)
    }

    private static func browserToken(client: MailOAuthClient, secret: String?) async throws -> MailOAuthToken {
        try GoogleCalendarAPI.requireOnline()
        let authorization = try MailOAuthAuthorization()
        let server = try MailOAuthCallbackServer(authorization: authorization)
        defer { server.cancel() }
        let redirect = try await server.start(provider: .google)
        let url = try authorization.url(client: client, redirect: redirect, email: "", scopes: GoogleCalendarAPI.scopes)
        try Task.checkCancellation()
        guard NSWorkspace.shared.open(url) else { throw MailOAuthError.cancelled }
        let callback = try await server.wait()
        let code = try authorization.code(from: callback, redirect: redirect)
        return try await MailOAuthHTTP().exchange(code: code, authorization: authorization, redirect: redirect, client: client,
                                                 secret: secret, scopes: GoogleCalendarAPI.scopes)
    }

    func disconnect() throws {
        try deleteToken()
        refresh?.cancel(); refresh = nil; generation = UUID()
        defaults.set(false, forKey: "calendarGoogleConnected")
        defaults.removeObject(forKey: "calendarGoogleEnabledIDs")
        connected = false; calendars = []; enabledIDs = []
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard calendars.contains(where: { $0.id == id }) else { return }
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        defaults.set(enabledIDs.sorted(), forKey: "calendarGoogleEnabledIDs")
    }

    func load(_ range: DateInterval, refreshCalendars: Bool = false) async throws -> [GoogleCalendarEvent] {
        guard connected else { throw GoogleCalendarError.signInRequired }
        let current = generation
        let token = try await credential()
        try Task.checkCancellation()
        guard generation == current, connected else { throw CancellationError() }
        if calendars.isEmpty || refreshCalendars {
            let list = try await api.calendars(token: token.accessToken)
            try Task.checkCancellation()
            guard generation == current, connected else { throw CancellationError() }
            acceptCalendars(list)
        }
        let result = try await api.events(in: range, calendars: calendars.filter { enabledIDs.contains($0.id) }, token: token.accessToken)
        try Task.checkCancellation()
        guard generation == current, connected else { throw CancellationError() }
        return result
    }

    private func acceptCalendars(_ list: [GoogleCalendarInfo]) {
        calendars = list
        if let saved = defaults.stringArray(forKey: "calendarGoogleEnabledIDs") { enabledIDs = Set(saved).intersection(list.map(\.id)) }
        else { enabledIDs = Set(list.filter { $0.selected != false }.map(\.id)) }
    }

    private func credential() async throws -> MailOAuthToken {
        if let refresh { return try await refresh.value }
        guard let stored = try readToken(), stored.clientID == clientID else { throw GoogleCalendarError.signInRequired }
        guard stored.needsRefresh else { return stored }
        let current = generation
        let client = try MailOAuthClient(provider: .google, clientID: clientID), secret = try readSecret(), http = http
        let task = Task { try await http.refresh(stored, client: client, secret: secret, scopes: GoogleCalendarAPI.scopes) }
        refresh = task
        defer { if generation == current { refresh = nil } }
        do {
            let token = try await task.value
            guard generation == current, connected else { throw CancellationError() }
            try saveToken(token)
            return token
        } catch let error as MailOAuthError {
            if error == .signInRequired || error == .invalidToken { throw GoogleCalendarError.signInRequired }
            throw GoogleCalendarError.unavailable
        }
    }
}
