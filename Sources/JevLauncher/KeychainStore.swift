import Foundation
import LocalAuthentication
import Security

enum KeychainStoreError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidStoredValue
    /// Reading would need a Keychain prompt, or access was refused.
    case unreadable(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "Keychain operation failed (status \(status))."
        case .invalidStoredValue, .unreadable:
            return "Re-enter your Jev key in Settings"
        }
    }
}

enum KeychainStore {
    private static let service = AppIdentity.bundleID
    private static let account = "typesafe-api-key"
    /// Where builds before 1.0 kept the key. A read moves it to the current item once.
    private static let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jev.launcher.typesafe",
        kSecAttrAccount as String: "api-key"
    ]

    /// Never shows a Keychain prompt; a read that needs one fails instead.
    static func read() throws -> String? {
        if let value = try read(baseQuery) { return value }
        guard let value = try read(legacyQuery) else { return nil }
        // The old item goes only after the new one is stored.
        if (try? save(value)) != nil { _ = SecItemDelete(silent(legacyQuery) as CFDictionary) }
        return value
    }

    private static func read(_ item: [String: Any]) throws -> String? {
        var query = silent(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try value(status: status, result: result)
    }

    /// The query with prompts disabled: an item that needs one fails instead.
    private static func silent(_ item: [String: Any]) -> [String: Any] {
        var query = item
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    static func value(status: OSStatus, result: CFTypeRef?) throws -> String? {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.invalidStoredValue
            }
            return value
        case errSecItemNotFound: return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem, errSecDecode:
            throw KeychainStoreError.unreadable(status)
        default: throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery.merge(attributes) { _, newValue in newValue }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(retryStatus)
            }
            return
        }
        throw KeychainStoreError.unexpectedStatus(addStatus)
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        // Remove means removed: an unmigrated old item must not come back on the next read.
        _ = SecItemDelete(silent(legacyQuery) as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// In-memory copy of the Jev key so searches never touch the Keychain on the main thread.
@MainActor
final class JevKeyCache: ObservableObject {
    enum State: Equatable { case unknown, missing, present(String), failed(String) }
    static let shared = JevKeyCache()
    @Published private(set) var state: State = .unknown
    private let reader: @Sendable () throws -> String?
    private var loading: Task<State, Never>?

    init(reader: @escaping @Sendable () throws -> String? = { try KeychainStore.read() }) { self.reader = reader }
    convenience init(key: String?) {
        self.init(reader: { key })
        state = key.map { $0.isEmpty ? .missing : .present($0) } ?? .missing
    }

    var hasKey: Bool { if case .present = state { return true }; return false }

    /// Reads the Keychain once off the main thread; later calls use the cached value.
    @discardableResult func load() async -> State {
        if state != .unknown { return state }
        if let loading { return await loading.value }
        let reader = self.reader
        let task = Task.detached { () -> State in
            do { return (try reader()).map { $0.isEmpty ? .missing : .present($0) } ?? .missing }
            catch { return .failed(error.localizedDescription) }
        }
        loading = Task { await task.value }
        let result = await task.value
        loading = nil
        if state == .unknown { state = result }
        return state
    }

    func save(_ key: String) throws {
        try KeychainStore.save(key)
        state = .present(key)
    }

    func delete() throws {
        try KeychainStore.delete()
        state = .missing
    }
}
