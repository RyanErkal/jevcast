import Foundation

/// Known mail services and their servers. Checked against each provider's published settings in
/// September 2026; see the notes on each case.
public enum MailProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Yahoo Mail, including regional addresses such as @yahoo.ie. Needs an app password.
    case yahoo
    /// iCloud Mail. Needs an app-specific password. SMTP is STARTTLS on 587 only.
    case icloud
    /// Gmail with an app password (2-Step Verification must be on).
    case gmail
    /// Outlook.com and Hotmail accept only OAuth since September 2024, which Jevcast does not offer yet.
    case outlook
    /// Any other IMAP and SMTP service.
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .yahoo: return "Yahoo"
        case .icloud: return "iCloud"
        case .gmail: return "Gmail"
        case .outlook: return "Outlook.com"
        case .other: return "Other IMAP"
        }
    }

    public var imap: MailServer? {
        switch self {
        case .yahoo: return MailServer(host: "imap.mail.yahoo.com", port: 993, security: .tls)
        case .icloud: return MailServer(host: "imap.mail.me.com", port: 993, security: .tls)
        case .gmail: return MailServer(host: "imap.gmail.com", port: 993, security: .tls)
        case .outlook: return MailServer(host: "outlook.office365.com", port: 993, security: .tls)
        case .other: return nil
        }
    }

    public var smtp: MailServer? {
        switch self {
        case .yahoo: return MailServer(host: "smtp.mail.yahoo.com", port: 465, security: .tls)
        case .icloud: return MailServer(host: "smtp.mail.me.com", port: 587, security: .startTLS)
        case .gmail: return MailServer(host: "smtp.gmail.com", port: 465, security: .tls)
        case .outlook: return MailServer(host: "smtp-mail.outlook.com", port: 587, security: .startTLS)
        case .other: return nil
        }
    }

    /// True when a password cannot sign in, so the account needs OAuth.
    public var needsOAuth: Bool { self == .outlook }

    /// True when the server files a copy of each sent message by itself, so Jevcast must not add
    /// another. Gmail and Outlook do. For the others Jevcast adds the copy to Sent.
    public var serverSavesSent: Bool { self == .gmail || self == .outlook }

    /// Where to make an app password.
    public var appPasswordURL: URL? {
        switch self {
        case .yahoo: return URL(string: "https://login.yahoo.com/account/security")
        case .icloud: return URL(string: "https://account.apple.com/account/manage")
        case .gmail: return URL(string: "https://myaccount.google.com/apppasswords")
        case .outlook, .other: return nil
        }
    }

    public var appPasswordHelp: String {
        switch self {
        case .yahoo: return "In Yahoo Account Security, choose Generate app password. Yahoo allows this only in a browser that has been signed in to Yahoo for several days, not in a private window."
        case .icloud: return "At account.apple.com, open Sign-In and Security, then App-Specific Passwords."
        case .gmail: return "Turn on 2-Step Verification, then make an app password at myaccount.google.com/apppasswords."
        case .outlook: return "Outlook.com needs OAuth sign-in, which Jevcast does not offer yet."
        case .other: return "Use the password your mail service gives for mail apps."
        }
    }

    /// The IMAP user name. iCloud asks for the part before the @; the others use the whole address.
    public func imapUsername(for email: String) -> String {
        self == .icloud ? String(email.split(separator: "@").first ?? Substring(email)) : email
    }

    /// The provider for an address, from its domain, or `.other`.
    public static func guess(for email: String) -> MailProvider {
        guard let domain = email.split(separator: "@").last?.lowercased() else { return .other }
        if domain.hasPrefix("yahoo.") || ["ymail.com", "rocketmail.com"].contains(domain) { return .yahoo }
        if ["icloud.com", "me.com", "mac.com"].contains(domain) { return .icloud }
        if ["gmail.com", "googlemail.com"].contains(domain) { return .gmail }
        if domain.hasPrefix("outlook.") || domain.hasPrefix("hotmail.") || domain.hasPrefix("live.") || domain == "msn.com" { return .outlook }
        return .other
    }
}

/// One account in Jevcast's own mail. Kept as JSON beside the mail store; the password lives
/// only in the Keychain.
public struct NativeMailAccount: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// Lower-case UUID. Also the host part of this account's mailbox URLs.
    public var id: String
    public var provider: MailProvider
    /// The name on sent mail.
    public var name: String
    public var email: String
    public var imap: MailServer
    public var smtp: MailServer
    public var imapUsername: String
    public var smtpUsername: String
    /// Adds each sent message to the Sent mailbox after sending.
    public var savesSentCopy: Bool

    public init(id: String = UUID().uuidString.lowercased(), provider: MailProvider, name: String, email: String,
                imap: MailServer, smtp: MailServer, imapUsername: String? = nil, smtpUsername: String? = nil, savesSentCopy: Bool? = nil) {
        self.id = id; self.provider = provider; self.name = name; self.email = email
        self.imap = imap; self.smtp = smtp
        self.imapUsername = imapUsername ?? provider.imapUsername(for: email)
        self.smtpUsername = smtpUsername ?? email
        self.savesSentCopy = savesSentCopy ?? !provider.serverSavesSent
    }

    /// An account with the provider's servers, or nil for `.other`, which needs servers typed in.
    public static func preset(_ provider: MailProvider, name: String, email: String) -> NativeMailAccount? {
        guard let imap = provider.imap, let smtp = provider.smtp else { return nil }
        return NativeMailAccount(provider: provider, name: name, email: email, imap: imap, smtp: smtp)
    }

    public var sender: MailContact { MailContact(name: name, address: email) }
}
