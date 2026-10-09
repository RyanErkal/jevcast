import AppKit
import LauncherCore

/// Where Mail reads mail: Apple Mail's own store, or the accounts Jevcast syncs itself.
enum MailBackend: String, CaseIterable, Identifiable {
    case appleMail, jevcast
    static let key = "mailBackend"
    static var current: MailBackend { UserDefaults.standard.string(forKey: key).flatMap(MailBackend.init(rawValue:)) ?? .appleMail }
    var id: String { rawValue }
    var title: String { self == .appleMail ? "Apple Mail" : "Jevcast accounts" }
}

/// Storage identity must initialize without entering the UI actor. Attachment reads run
/// in background tasks, including before a live mail center has been created.
enum NativeMailLocation {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Jevcast/Mail", isDirectory: true)
}

/// Jevcast's own mail accounts: the account list beside the store, passwords in the Keychain, and
/// the engine that syncs them. The mail reader and `MailActions` use the `nonisolated` parts from
/// any thread.
@MainActor
final class NativeMailCenter: ObservableObject {
    static let shared = NativeMailCenter()

    nonisolated static var root: URL { NativeMailLocation.root }
    nonisolated static var accountsFile: URL { root.appendingPathComponent("accounts.json") }
    /// Posted, on the main queue, after the store changes.
    nonisolated static let changed = Notification.Name("JevcastNativeMailChanged")

    @Published private(set) var accounts: [NativeMailAccount] = []
    @Published private(set) var states: [String: MailAccountSync.State] = [:]
    @Published private(set) var lastSuccessfulSync: [String: Date] = [:]
    @Published private(set) var offlinePolicies: [String: MailOfflinePolicy] = [:]
    @Published private(set) var offlineCoverage: [String: [MailOfflineMailboxCoverage]] = [:]
    @Published private(set) var offlineStorageReports: [String: MailOfflineStorageReport] = [:]
    @Published private(set) var offlineQueueStatus: [String: MailOfflineQueueStatus] = [:]
    @Published private(set) var offlineQueuedActions: [String: [MailOfflineAction]] = [:]
    /// A note that did not stop sync, such as a sent message whose copy in Sent failed.
    @Published private(set) var notices: [String: String] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var backend: MailBackend
    private let defaults: UserDefaults?
    private static let lastSyncKey = "mailLastSuccessfulSync"
    lazy var recovery = MailAccountRecovery { [weak self] account, password in
        guard let self else { throw CancellationError() }
        if account.authentication == .oauth { try await self.reconnectOAuth(account) }
        else {
            guard let password, !password.isEmpty else { throw MailError.notFound("Enter an app password for this account.") }
            try await self.updatePassword(account, password: password)
        }
    }
    private var engine: NativeMailEngine?
    private var offlineStore: NativeMailStore?
    private var wakeObserver: NSObjectProtocol?

    init(backend: MailBackend = .current, accounts: [NativeMailAccount] = [], defaults: UserDefaults? = .standard) {
        self.backend = backend; self.accounts = accounts; self.defaults = defaults
        lastSuccessfulSync = defaults?.dictionary(forKey: Self.lastSyncKey) as? [String: Date] ?? [:]
    }

    func recordState(_ id: String, _ state: MailAccountSync.State) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        states[id] = state
        if case .ready(let date) = state {
            lastSuccessfulSync[id] = date
            defaults?.set(lastSuccessfulSync, forKey: Self.lastSyncKey)
            Task { [weak self] in
                await self?.engine?.reconcileOfflineActions()
                await self?.refreshOfflineState()
            }
        }
    }

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var runningEngine: NativeMailEngine?

    // MARK: For the reader and MailActions, from any thread

    nonisolated static var isActive: Bool { MailBackend.current == .jevcast }

    /// The engine while Jevcast accounts are the mail source.
    nonisolated static var activeEngine: NativeMailEngine? { isActive ? lock.withLock { runningEngine } : nil }

    nonisolated static func isNativeRoot(_ path: String) -> Bool { path == NativeMailLocation.root.path }

    /// Ready once there is an account and a store to read.
    nonisolated static func status() -> MailStore.Status {
        guard !loadAccounts().isEmpty, FileManager.default.fileExists(atPath: NativeMailStore.indexPath(root: root)) else { return .noMail }
        return .ready(root: root.path)
    }

    nonisolated static func loadAccounts() -> [NativeMailAccount] {
        guard let data = try? Data(contentsOf: accountsFile) else { return [] }
        // An account ID names a folder, so an edited file cannot point outside the mail folder.
        return ((try? JSONDecoder().decode([NativeMailAccount].self, from: data)) ?? []).compactMap { try? $0.validated() }
    }

    nonisolated static func keychainAccount(_ id: String) -> String { "mail-" + id }

    /// The account's app password from the Keychain, read without a prompt.
    nonisolated static func credential(for account: NativeMailAccount) async throws -> MailCredential {
        try MailIOPolicy.requireOnline()
        if account.authentication == .oauth { return try await MailOAuthCredentials.shared.credential(for: account) }
        let password: String?
        do { password = try KeychainStore.read(account: keychainAccount(account.id)) } catch {
            throw MailError.notFound("The saved mail password could not be accessed. Unlock your login Keychain, then retry sync. If access still fails, enter the app password again in Settings › Mail.")
        }
        guard let password, !password.isEmpty else {
            throw MailError.signInFailed("No password is saved for \(account.email). Enter it in Settings › Mail.")
        }
        return .password(password)
    }

    // MARK: Lifecycle

    /// At launch: loads the accounts and starts sync when Jevcast accounts are the mail source.
    func start() {
        accounts = Self.loadAccounts()
        backend = MailBackend.current
        Task { await refreshOfflineState() }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                guard let engine = NativeMailCenter.activeEngine else { return }
                Task { await engine.wake() }
            }
        }
        guard Self.isActive, !accounts.isEmpty, let engine = ensureEngine() else { return }
        let accounts = self.accounts
        Task { await engine.setAccounts(accounts) }
    }

    func setBackend(_ new: MailBackend) {
        UserDefaults.standard.set(new.rawValue, forKey: MailBackend.key)
        backend = new
        if new == .jevcast { start() } else if let engine { Task { await engine.stopAll() } }
        Self.postChanged()
    }

    private func ensureEngine() -> NativeMailEngine? {
        if let engine { return engine }
        do {
            let store = try NativeMailStore(root: Self.root)
            offlineStore = store
            let engine = NativeMailEngine(
                store: store,
                credential: { account in try await NativeMailCenter.credential(for: account) },
                changed: { NativeMailCenter.postChanged() },
                report: { [weak self] id, state in Task { @MainActor in self?.recordState(id, state) } },
                notice: { id, text in Task { @MainActor in NativeMailCenter.shared.notices[id] = text } })
            self.engine = engine
            Self.lock.withLock { Self.runningEngine = engine }
            problem = nil
            return engine
        } catch {
            problem = "The mail store could not be opened: " + error.localizedDescription
            return nil
        }
    }

    // MARK: Offline storage

    private func openOfflineStore() throws -> NativeMailStore {
        if let offlineStore { return offlineStore }
        let store = try NativeMailStore(root: Self.root)
        offlineStore = store
        return store
    }

    func refreshOfflineState() async {
        guard !accounts.isEmpty || offlineStore != nil else { return }
        guard let store = try? openOfflineStore() else { return }
        let IDs = accounts.map(\.id)
        if let policies = try? await store.offlinePolicies(for: IDs) { offlinePolicies = policies }
        if let coverage = try? await store.offlineCoverage() {
            offlineCoverage = Dictionary(grouping: coverage, by: \.accountID)
        }
        var storage: [String: MailOfflineStorageReport] = [:]
        for id in IDs { if let report = try? await store.offlineStorage(accountID: id) { storage[id] = report } }
        offlineStorageReports = storage
        var queue: [String: MailOfflineQueueStatus] = [:]
        var actions: [String: [MailOfflineAction]] = [:]
        for id in IDs {
            if let status = try? await store.offlineQueueStatus(accountID: id) { queue[id] = status }
            if let queued = try? await store.offlineActions(accountID: id) { actions[id] = queued }
        }
        offlineQueueStatus = queue
        offlineQueuedActions = actions
    }

    func offlinePolicy(for accountID: String) async -> MailOfflinePolicy? {
        guard accounts.contains(where: { $0.id == accountID }), let store = try? openOfflineStore() else { return nil }
        let policy = try? await store.offlinePolicy(for: accountID)
        if let policy { offlinePolicies[accountID] = policy }
        return policy
    }

    func setOfflinePolicy(_ policy: MailOfflinePolicy, for accountID: String) async throws {
        guard accounts.contains(where: { $0.id == accountID }) else { throw MailError.notFound("This mail account is no longer available.") }
        let store = try openOfflineStore()
        try await store.saveOfflinePolicy(policy, for: accountID)
        offlinePolicies[accountID] = policy
        if let engine, Self.isActive { await engine.syncAccount(accountID) }
        await refreshOfflineState()
    }

    func setOfflinePaused(_ paused: Bool, for accountID: String) async throws {
        guard var policy = await offlinePolicy(for: accountID) else { throw MailError.notFound("This mail account is no longer available.") }
        policy.paused = paused
        try await setOfflinePolicy(policy, for: accountID)
    }

    func clearOfflineCache(accountID: String? = nil) async throws {
        let store = try openOfflineStore()
        try await store.clearOfflineCache(accountID: accountID)
        await refreshOfflineState()
        Self.postChanged()
    }

    func retryOfflineQueue(accountID: String? = nil) async {
        guard let store = try? openOfflineStore() else { return }
        let actions = (try? await store.offlineActions(accountID: accountID, states: [.failed])) ?? []
        for var action in actions {
            action.state = .pending; action.lastError = nil; action.updatedAt = Date()
            try? await store.updateOfflineAction(action)
        }
        await engine?.reconcileOfflineActions()
        await refreshOfflineState()
    }

    /// Explicitly retries one failed or review action after the user checked the server state.
    /// Review actions never retry from reconnect alone.
    func retryOfflineAction(_ id: UUID) async {
        guard let store = try? openOfflineStore(), let actions = try? await store.offlineActions(), let action = actions.first(where: { $0.id == id }) else { return }
        var pending = action; pending.state = .pending; pending.lastError = nil; pending.updatedAt = Date()
        try? await store.updateOfflineAction(pending)
        await engine?.reconcileOfflineActions()
        await refreshOfflineState()
    }

    /// Coalesces many store changes into one notice per main-queue turn.
    nonisolated private static let pending = PendingFlag()
    nonisolated static func postChanged() {
        guard pending.set() else { return }
        DispatchQueue.main.async {
            pending.clear()
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // MARK: Accounts

    /// Checks the servers and the password, then saves the account. The first account makes
    /// Jevcast accounts the mail source.
    func add(_ account: NativeMailAccount, password: String) async throws {
        try MailIOPolicy.requireOnline()
        let account = try account.validated()
        guard let engine = ensureEngine() else { throw MailError.notFound(problem ?? "The mail store could not be opened.") }
        guard !accounts.contains(where: { $0.email.caseInsensitiveCompare(account.email) == .orderedSame }) else {
            throw MailError.notFound("\(account.email) is already added.")
        }
        try await engine.verify(account, credential: .password(password))
        try Task.checkCancellation()
        try KeychainStore.save(password, account: Self.keychainAccount(account.id))
        accounts.append(account)
        do { try saveAccounts() }
        catch { accounts.removeAll { $0.id == account.id }; try? KeychainStore.delete(account: Self.keychainAccount(account.id)); throw error }
        if accounts.count == 1, backend == .appleMail { setBackend(.jevcast); return }
        if Self.isActive { await engine.setAccounts(accounts) }
    }

    func addOAuth(_ account: NativeMailAccount) async throws {
        try MailIOPolicy.requireOnline()
        var account = account
        account.authentication = .oauth
        account = try account.validated()
        guard !accounts.contains(where: { $0.email.caseInsensitiveCompare(account.email) == .orderedSame }) else {
            throw MailError.notFound("This address is already added.")
        }
        let token = try await MailOAuthSignIn.authenticate(account)
        try Task.checkCancellation()
        guard let engine = ensureEngine() else { throw MailError.notFound("The mail store could not be opened.") }
        try await engine.verify(account, credential: .oauth2(accessToken: token.accessToken))
        try Task.checkCancellation()
        try MailOAuthCredentials.save(token, accountID: account.id)
        accounts.append(account)
        do { try saveAccounts() }
        catch { accounts.removeAll { $0.id == account.id }; try? KeychainStore.delete(account: MailOAuthCredentials.key(account.id)); throw error }
        if accounts.count == 1, backend == .appleMail { setBackend(.jevcast) }
        else if Self.isActive { await engine.setAccounts(accounts) }
    }

    func reconnectOAuth(_ account: NativeMailAccount) async throws {
        try MailIOPolicy.requireOnline()
        try requireAccount(account)
        let token = try await MailOAuthSignIn.authenticate(account)
        try Task.checkCancellation()
        guard let engine = ensureEngine() else { throw MailError.notFound("The mail store could not be opened.") }
        try await engine.verify(account, credential: .oauth2(accessToken: token.accessToken))
        try Task.checkCancellation()
        await MailOAuthCredentials.shared.cancelRefresh(account.id)
        try Task.checkCancellation()
        try requireAccount(account)
        try MailOAuthCredentials.save(token, accountID: account.id)
        notices[account.id] = nil
        if Self.isActive { await engine.restart(account.id) }
    }

    func updateSignature(_ account: NativeMailAccount, signature: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let before = accounts[index]
        accounts[index].signature = signature
        do { try saveAccounts() } catch { accounts[index] = before; throw error }
    }

    func updateFolders(_ account: NativeMailAccount, mapping: [String: MailMailbox.Role]) throws {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let before = accounts[index]
        accounts[index].mailboxRoles = mapping
        do { try saveAccounts() } catch { accounts[index] = before; throw error }
        if Self.isActive, let engine { let list = accounts; Task { await engine.setAccounts(list) } }
    }

    /// Removes the account and its mail from this Mac. The mail stays on the server.
    func remove(_ account: NativeMailAccount) async {
        guard !MailIOPolicy.isOffline else { return }
        recovery.cancel(account.id)
        accounts.removeAll { $0.id == account.id }
        try? saveAccounts()
        if let engine {
            try? await engine.removeData(for: account.id)
            await engine.setAccounts(Self.isActive ? accounts : [])
        }
        await MailOAuthCredentials.shared.cancelRefresh(account.id)
        try? KeychainStore.delete(account: Self.keychainAccount(account.id))
        try? KeychainStore.delete(account: MailOAuthCredentials.key(account.id))
        states[account.id] = nil
        lastSuccessfulSync[account.id] = nil
        defaults?.set(lastSuccessfulSync, forKey: Self.lastSyncKey)
        notices[account.id] = nil
        offlinePolicies[account.id] = nil
        offlineCoverage[account.id] = nil
        offlineStorageReports[account.id] = nil
        offlineQueueStatus[account.id] = nil
        offlineQueuedActions[account.id] = nil
        Self.postChanged()
    }

    /// Saves a new app password after the server accepts it, and starts sync again.
    func updatePassword(_ account: NativeMailAccount, password: String) async throws {
        try MailIOPolicy.requireOnline()
        try requireAccount(account)
        guard let engine = ensureEngine() else { throw MailError.notFound(problem ?? "The mail store could not be opened.") }
        try await engine.verify(account, credential: .password(password))
        try Task.checkCancellation()
        try requireAccount(account)
        do { try KeychainStore.save(password, account: Self.keychainAccount(account.id)) }
        catch is KeychainStoreError {
            throw MailError.notFound("The mail password could not be saved. Unlock your login Keychain, then reconnect.")
        }
        notices[account.id] = nil
        await engine.restart(account.id)
    }

    func syncNow() {
        guard !MailIOPolicy.isOffline else { return }
        guard let engine = Self.activeEngine else { return }
        Task { await engine.sync(.everything) }
    }

    /// A manual retry wakes the existing loop. Rejected sign-in still needs reconnect.
    func retrySync(_ id: String) {
        guard !MailIOPolicy.isOffline, Self.isActive, let engine = Self.activeEngine,
              accounts.contains(where: { $0.id == id }) else { return }
        if case .failed(_, signIn: true) = states[id] { return }
        Task { await engine.syncAccount(id) }
    }

    private func requireAccount(_ account: NativeMailAccount) throws {
        guard accounts.contains(account) else { throw MailError.notFound("This account changed or was removed. Open its current details and try again.") }
    }

    func reportSetupError(_ text: String) { problem = text }

    func clearNotice(_ id: String) { notices[id] = nil }

    private func saveAccounts() throws {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: Self.accountsFile, options: .atomic)
        chmod(Self.accountsFile.path, 0o600)
    }
}

/// A flag set from any thread, cleared on the main queue.
final class PendingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    /// True when this call turned the flag on.
    func set() -> Bool { lock.withLock { if on { return false }; on = true; return true } }
    func clear() { lock.withLock { on = false } }
}
