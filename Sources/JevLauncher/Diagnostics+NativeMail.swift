import Foundation
import LauncherCore

extension Diagnostics {
    /// Reads local setup only. No authorization, token refresh, mail transport, or Apple Events.
    static func mailSetup() {
        for provider in MailOAuthProvider.allCases {
            let valid = (try? MailOAuthSetup.client(provider)) != nil
            print(provider.title + " client ID: " + (valid ? "valid" : "missing or invalid"))
        }
        do {
            let secret = try KeychainStore.read(account: MailOAuthSetup.googleSecretKey)
            print("Google desktop secret: " + (secret?.isEmpty == false ? "saved and readable" : "not saved"))
        } catch {
            print("Google desktop secret: unreadable; save it again in Settings > Mail")
        }
    }

    /// `--diagnose-native-mail`: for each Jevcast account, signs in to IMAP and SMTP with the saved
    /// password and prints the server's capabilities, mailbox roles and counts, and timings. It
    /// changes nothing and never prints mailbox names, subjects, or addresses.
    static func nativeMail() {
        let accounts = NativeMailCenter.loadAccounts()
        print("Mail source: " + MailBackend.current.title)
        print("Jevcast accounts: \(accounts.count)")
        Task {
            for (number, account) in accounts.enumerated() {
                print("\nAccount \(number + 1): \(account.provider.title), IMAP \(account.imap.host):\(account.imap.port) \(account.imap.security.rawValue), "
                      + "SMTP \(account.smtp.host):\(account.smtp.port) \(account.smtp.security.rawValue), copy to Sent: \(account.savesSentCopy ? "yes" : "no")")
                await check(account)
            }
            fflush(stdout)
            exit(0)
        }
        RunLoop.main.run()
    }

    private static func check(_ account: NativeMailAccount) async {
        let credential: @Sendable () async throws -> MailCredential = { try await NativeMailCenter.credential(for: account) }
        let client = IMAPClient(settings: .init(server: account.imap, username: account.imapUsername), credential: credential)
        func ms(_ start: CFAbsoluteTime) -> Int { Int((CFAbsoluteTimeGetCurrent() - start) * 1000) }
        do {
            var start = CFAbsoluteTimeGetCurrent()
            try await client.verify()
            print("  IMAP sign-in: \(ms(start)) ms")
            print("  Capabilities: " + (await client.capabilities).sorted().joined(separator: " "))
            start = CFAbsoluteTimeGetCurrent()
            let entries = try await client.listMailboxes()
            print("  Mailboxes: \(entries.count) (\(entries.filter(\.selectable).count) selectable) in \(ms(start)) ms")
            let special = ["\\Sent", "\\Drafts", "\\Trash", "\\Junk", "\\Archive", "\\All", "\\Flagged", "\\Important"]
            print("  Special use: " + special.map { flag in "\(flag)=\(entries.filter { $0.has(flag) }.count)" }.joined(separator: " "))
            start = CFAbsoluteTimeGetCurrent()
            let inbox = try await client.select("INBOX")
            print("  INBOX: \(inbox.exists) messages, UIDNEXT \(inbox.uidNext.map(String.init) ?? "none"), "
                  + "HIGHESTMODSEQ \(inbox.highestModSeq == nil ? "none" : "yes"), selected in \(ms(start)) ms")
            if let limit = await client.messageLimit, Int(inbox.exists) > limit {
                // One SEARCH over the whole folder would pass the limit and be refused.
                print("  INBOX UIDs: not listed; the server's MESSAGELIMIT is \(limit)")
            } else {
                start = CFAbsoluteTimeGetCurrent()
                let all = try await client.search("ALL", in: "INBOX", validity: inbox.uidValidity)
                print("  INBOX UIDs found: \(all.count) in \(ms(start)) ms" + (all.count < Int(inbox.exists) ? " (fewer than the message count)" : ""))
            }
            await client.logout()
        } catch {
            print("  IMAP failed: " + error.localizedDescription)
            await client.logout()
        }
        do {
            let start = CFAbsoluteTimeGetCurrent()
            try await SMTPClient(settings: .init(server: account.smtp, username: account.smtpUsername), credential: credential).verify()
            print("  SMTP sign-in: \(ms(start)) ms")
        } catch {
            print("  SMTP failed: " + error.localizedDescription)
        }
    }
}
