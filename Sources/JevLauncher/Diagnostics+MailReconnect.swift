import Foundation
import LauncherCore

extension Diagnostics {
    /// Explicit browser sign-in for one existing account. No sync, message fetch, or send.
    static func reconnectMail(email: String) {
        let matches = NativeMailCenter.loadAccounts().filter { $0.email == email }
        guard matches.count == 1, let account = matches.first, account.authentication == .oauth else {
            print("Reconnect failed: specify exactly one configured OAuth account.")
            return
        }
        Task {
            do {
                print("Opening provider sign-in for the configured account.")
                fflush(stdout)
                let token = try await MailOAuthSignIn.authenticate(account)
                let credential: @Sendable () async throws -> MailCredential = { .oauth2(accessToken: token.accessToken) }
                let imap = IMAPClient(settings: .init(server: account.imap, username: account.imapUsername), credential: credential)
                do { try await imap.verify() }
                catch { await imap.logout(); throw error }
                await imap.logout()
                print("IMAP sign-in accepted.")
                try await SMTPClient(settings: .init(server: account.smtp, username: account.smtpUsername), credential: credential).verify()
                print("SMTP sign-in accepted.")
                try Task.checkCancellation()
                guard NativeMailCenter.loadAccounts().filter({ $0.id == account.id }) == [account] else {
                    throw MailError.notFound("The account changed during sign-in. Reconnect it again.")
                }
                try MailOAuthCredentials.save(token, accountID: account.id)
                print("Reconnect complete. Sign-in saved in Keychain. Restart Jevcast to resume sync.")
                fflush(stdout)
                exit(0)
            } catch {
                print("Reconnect failed: " + error.localizedDescription)
                fflush(stdout)
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
