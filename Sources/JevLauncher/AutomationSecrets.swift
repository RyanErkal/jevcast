import Foundation
import LocalAuthentication
import Security

/// Script-task secrets in the Keychain. The runner reads the same service (`SecretStore` in JevRunner)
/// and passes each value to that script's process only. Values never go into automation files.
enum AutomationSecrets {
    static let service = "com.ryanerkal.jevlauncher.automations"

    /// An environment variable name: a letter or "_", then letters, digits, or "_", up to 64 characters.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, (1...64).contains(name.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        return (CharacterSet.letters.contains(first) || first == "_") && name.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    static func save(name: String, value: String) throws {
        guard isValidName(name) else { throw KeychainStoreError.invalidStoredValue }
        let base = query(name)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainStoreError.unexpectedStatus(update) }
        let add = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(add) }
    }

    static func delete(name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError.unexpectedStatus(status) }
    }

    /// True when an item exists. Never reads the value and never shows a prompt.
    static func exists(name: String) -> Bool {
        var q = query(name)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }
}
