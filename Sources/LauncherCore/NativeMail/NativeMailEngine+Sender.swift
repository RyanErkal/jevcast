import Foundation

/// A From identity that the app has checked against a provider-authorized alias.
///
/// `accountAddress` is the canonical account that owns the IMAP/SMTP credential. It is
/// intentionally separate from `address`, which may be an authorized provider alias. The
/// transport always authenticates and uses the canonical account as its SMTP envelope sender.
public struct NativeMailSender: Codable, Sendable, Equatable, Hashable {
    public let address: String
    public let name: String
    public let accountAddress: String
    public let providerAuthorized: Bool

    public init(address: String, name: String = "", accountAddress: String,
                providerAuthorized: Bool) {
        self.address = address
        self.name = name
        self.accountAddress = accountAddress
        self.providerAuthorized = providerAuthorized
    }

    public var contact: MailContact { MailContact(name: name, address: address) }

    public static func canonical(for account: NativeMailAccount) -> NativeMailSender {
        NativeMailSender(address: account.email, name: account.name,
                         accountAddress: account.email, providerAuthorized: true)
    }

    /// Validates the app-provided identity at the native transport boundary. This does not
    /// compare the selected alias to the account address. It only proves that the canonical
    /// account owns the credential and that the selected address is safe and authorized.
    public func validated(for account: NativeMailAccount) throws -> NativeMailSender {
        let safeName = name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        guard providerAuthorized,
              SMTPClient.isSafeAddress(address),
              SMTPClient.isSafeAddress(accountAddress),
              accountAddress.caseInsensitiveCompare(account.email) == .orderedSame,
              safeName else {
            throw MailError.notFound("The selected sending identity is not a verified address for this account.")
        }
        return self
    }
}
