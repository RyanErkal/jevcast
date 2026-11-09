import AppKit
import Combine
import LauncherCore

/// Calendar has its own token and opt-in. A Mail sign-in never grants Calendar access.
@MainActor
final class GoogleCalendarAccount: ObservableObject {
    static let shared = GoogleCalendarAccount()
    nonisolated static let tokenKey = "calendar-google-oauth-token"
    nonisolated static let clientKey = "calendarGoogleClientID"
    nonisolated static let secretKey = "calendar-google-client-secret"
    /// Empty for the first account, which keeps the original storage names. Another account has a
    /// short ID, and every one of its storage names ends in it.
    let slot: String
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
    private var suffix: String { Self.suffix(slot) }
    nonisolated static func suffix(_ slot: String) -> String { slot.isEmpty ? "" : "." + slot }
    private var connectedKey: String { "calendarGoogleConnected" + suffix }
    private var enabledKey: String { "calendarGoogleEnabledIDs" + suffix }
    private var clientDefaultsKey: String { Self.clientKey + suffix }

    init(slot: String = "", defaults: UserDefaults = .standard, api: GoogleCalendarAPI = .init(), http: MailOAuthHTTP = .init(),
         readToken: (() throws -> MailOAuthToken?)? = nil, saveToken: ((MailOAuthToken) throws -> Void)? = nil,
         deleteToken: (() throws -> Void)? = nil, readSecret: (() throws -> String?)? = nil,
         writeSecret: ((String?) throws -> Void)? = nil,
         authenticate: @escaping @MainActor (MailOAuthClient, String?) async throws -> MailOAuthToken = { client, secret in
             try await browserToken(client: client, secret: secret)
         }) {
        let suffix = Self.suffix(slot)
        let tokenAccount = Self.tokenKey + suffix, secretAccount = Self.secretKey + suffix, clientKey = Self.clientKey + suffix
        self.slot = slot
        self.defaults = defaults; self.api = api; self.http = http
        self.readToken = readToken ?? {
            try GoogleCalendarAPI.requireOnline()
            guard let text = try KeychainStore.read(account: tokenAccount), let data = text.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(MailOAuthToken.self, from: data)
        }
        self.saveToken = saveToken ?? { try KeychainStore.save(String(decoding: JSONEncoder().encode($0), as: UTF8.self), account: tokenAccount) }
        self.deleteToken = deleteToken ?? { try KeychainStore.delete(account: tokenAccount) }
        self.readSecret = readSecret ?? {
            try GoogleCalendarAPI.requireOnline()
            if let secret = try KeychainStore.read(account: secretAccount) { return secret }
            let defaults = UserDefaults.standard
            let own = defaults.string(forKey: clientKey)
            // Another account can reuse the first Calendar account's client, then Mail's.
            if !suffix.isEmpty, let first = defaults.string(forKey: Self.clientKey), own == nil || own == first,
               let secret = try KeychainStore.read(account: Self.secretKey) { return secret }
            let mailID = defaults.string(forKey: MailOAuthSetup.key(.google))
            let calendarID = own ?? defaults.string(forKey: Self.clientKey) ?? mailID
            guard let mailID, calendarID == mailID else { return nil }
            return try KeychainStore.read(account: MailOAuthSetup.googleSecretKey)
        }
        self.writeSecret = writeSecret ?? {
            if let secret = $0 { try KeychainStore.save(secret, account: secretAccount) }
            else { try KeychainStore.delete(account: secretAccount) }
        }
        self.authenticate = authenticate
        connected = defaults.bool(forKey: "calendarGoogleConnected" + suffix)
        enabledIDs = Set(defaults.stringArray(forKey: "calendarGoogleEnabledIDs" + suffix) ?? [])
    }

    var clientID: String {
        defaults.string(forKey: clientDefaultsKey) ?? defaults.string(forKey: Self.clientKey) ?? defaults.string(forKey: MailOAuthSetup.key(.google)) ?? ""
    }
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
        defaults.set(client.clientID, forKey: clientDefaultsKey)
        defaults.set(true, forKey: connectedKey)
        // A first Google sign-in shows Google. A further account keeps a merged view merged.
        if defaults.string(forKey: "calendarSource") != CalendarPage.Source.all.rawValue {
            defaults.set(CalendarPage.Source.google.rawValue, forKey: "calendarSource")
        }
        refresh?.cancel(); refresh = nil; generation = UUID()
        connected = true
        // Another person may have signed in. Events fetched before belong to the old sign-in.
        CalendarPage.clearCache()
        defaults.removeObject(forKey: enabledKey)
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
        defaults.set(false, forKey: connectedKey)
        defaults.removeObject(forKey: enabledKey)
        connected = false; calendars = []; enabledIDs = []
        CalendarPage.clearCache()
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard calendars.contains(where: { $0.id == id }) else { return }
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        defaults.set(enabledIDs.sorted(), forKey: enabledKey)
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
        if let saved = defaults.stringArray(forKey: enabledKey) { enabledIDs = Set(saved).intersection(list.map(\.id)) }
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

/// Every connected Google Calendar account. The first one is the original account; more can be added.
@MainActor
final class GoogleCalendarAccounts: ObservableObject {
    static let shared = GoogleCalendarAccounts(primary: .shared, defaults: .standard, make: { GoogleCalendarAccount(slot: $0) })
    @Published private(set) var all: [GoogleCalendarAccount]
    private let defaults: UserDefaults?
    private let make: (String) -> GoogleCalendarAccount
    private var watchers: [ObjectIdentifier: AnyCancellable] = [:]
    private static let slotsKey = "calendarGoogleSlots"

    init(primary: GoogleCalendarAccount, defaults: UserDefaults?, make: @escaping (String) -> GoogleCalendarAccount) {
        self.defaults = defaults; self.make = make
        let slots = (defaults?.stringArray(forKey: Self.slotsKey) ?? []).filter(Self.validSlot)
        all = [primary] + slots.map(make)
        all.forEach(watch)
    }

    var connected: [GoogleCalendarAccount] { all.filter(\.connected) }

    static func validSlot(_ slot: String) -> Bool {
        !slot.isEmpty && slot.count <= 16 && slot.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The account a sign-in should fill: the first one while it is free, otherwise a new one.
    func accountForSignIn() -> GoogleCalendarAccount {
        if let free = all.first(where: { !$0.connected }) { return free }
        let slot = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let account = make(slot)
        all.append(account); watch(account); save()
        return account
    }

    /// Signs the account out on this Mac. A further account also leaves the list.
    func disconnect(_ account: GoogleCalendarAccount) throws {
        try account.disconnect()
        prune()
    }

    /// Drops further accounts that never finished sign-in or were disconnected.
    func prune() {
        let kept = all.filter { $0.slot.isEmpty || $0.connected }
        guard kept.count != all.count else { return }
        for gone in all where !kept.contains(where: { $0 === gone }) { watchers[ObjectIdentifier(gone)] = nil }
        all = kept; save()
    }

    private func save() { defaults?.set(all.map(\.slot).filter { !$0.isEmpty }, forKey: Self.slotsKey) }
    private func watch(_ account: GoogleCalendarAccount) {
        watchers[ObjectIdentifier(account)] = account.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
