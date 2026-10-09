import XCTest
@testable import LauncherCore

final class NativeMailSenderTests: XCTestCase {
    private let account = NativeMailAccount(
        id: "sender-account", provider: .other, name: "Canonical", email: "me@example.com",
        imap: MailServer(host: "imap.example.com", port: 993, security: .tls),
        smtp: MailServer(host: "smtp.example.com", port: 465, security: .tls))

    func testVerifiedAliasRetainsCanonicalOwnerWithoutComparingAliasAddress() throws {
        let alias = NativeMailSender(address: "sales@other.example", name: "Sales",
                                     accountAddress: account.email, providerAuthorized: true)
        let validated = try alias.validated(for: account)
        XCTAssertEqual(validated, alias)
        XCTAssertEqual(alias.contact.address, "sales@other.example")
    }

    func testAliasWithDifferentCredentialOwnerOrAuthorizationIsRefused() {
        let wrongOwner = NativeMailSender(address: "sales@other.example", accountAddress: "other@example.com",
                                          providerAuthorized: true)
        XCTAssertThrowsError(try wrongOwner.validated(for: account))

        let unverified = NativeMailSender(address: "sales@other.example", accountAddress: account.email,
                                          providerAuthorized: false)
        XCTAssertThrowsError(try unverified.validated(for: account))
    }
}
