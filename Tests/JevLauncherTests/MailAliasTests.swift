import XCTest
import LauncherCore
@testable import JevLauncher

final class MailAliasTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var account: NativeMailAccount!

    override func setUpWithError() throws {
        suiteName = "mail-alias-tests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        account = try XCTUnwrap(NativeMailAccount.preset(.gmail, name: "Me", email: "me@example.com"))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testOnlyExplicitProviderAuthorizedAliasIsStored() throws {
        let alias = MailAlias(accountID: account.id, address: "team@example.org", name: "Team",
                              signature: "Team signature", providerAuthorized: true)
        try MailAliasStore.save([alias], accounts: [account], defaults: defaults)
        XCTAssertEqual(MailAliasStore.aliases(for: account, defaults: defaults), [alias])

        let unchecked = MailAlias(accountID: account.id, address: "spoof@example.org", name: "Spoof",
                                  signature: "", providerAuthorized: false)
        XCTAssertThrowsError(try MailAliasStore.save([unchecked], accounts: [account], defaults: defaults))
        XCTAssertEqual(MailAliasStore.aliases(for: account, defaults: defaults), [alias])
    }

    func testConfirmedAliasCanSendNativelyWithSeparateCredentialOwner() throws {
        let identity = MailSendingIdentity(accountID: account.id, address: "team@example.org", name: "Team",
                                           signature: "", accountAddress: account.email, providerAuthorized: true)
        XCTAssertTrue(identity.isAlias)
        XCTAssertTrue(identity.canSend(backend: .jevcast))
        XCTAssertTrue(identity.canSend(backend: .appleMail))
        let sender = try identity.nativeSender(for: account)
        XCTAssertEqual(sender.address, identity.address)
        XCTAssertEqual(sender.accountAddress, account.email)
        XCTAssertEqual(sender.name, "Team")
    }

    func testAliasWithoutProviderAuthorizationCannotMapToNativeSender() {
        let identity = MailSendingIdentity(accountID: account.id, address: "spoof@example.org", name: "Spoof",
                                           signature: "", accountAddress: account.email, providerAuthorized: false)
        XCTAssertFalse(identity.canSend(backend: .jevcast))
        XCTAssertThrowsError(try identity.nativeSender(for: account))
    }
}
