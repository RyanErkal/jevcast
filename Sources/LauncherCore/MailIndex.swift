import Foundation

/// A mailbox from Apple Mail's `Envelope Index`, such as `imap://<account>/INBOX`.
public struct MailMailbox: Equatable, Sendable, Identifiable, Hashable {
    public let rowID: Int64
    public let url: String
    public let unread: Int
    public let total: Int
    /// The role the server gave the mailbox (IMAP special use), which wins over its name.
    /// Only Jevcast's own mail store records it.
    public let serverRole: Role?
    /// The server's own counts, including mail not on this Mac. Only Jevcast's own store has them.
    public let serverTotal: Int?
    public let serverUnread: Int?
    public init(rowID: Int64, url: String, unread: Int, total: Int, serverRole: Role? = nil, serverTotal: Int? = nil, serverUnread: Int? = nil) {
        self.rowID = rowID; self.url = url; self.unread = unread; self.total = total; self.serverRole = serverRole
        self.serverTotal = serverTotal; self.serverUnread = serverUnread
    }
    public var id: Int64 { rowID }

    /// The account's ID: the URL host, which is also the folder name under `~/Library/Mail/V…`.
    public var accountID: String { URL(string: url)?.host ?? "" }
    /// The path Mail's AppleScript uses for the mailbox, such as "INBOX" or "[Gmail]/All Mail".
    /// A URL with an empty host, such as `local:///Inbox`, still has its path.
    public var path: String {
        let raw = url.components(separatedBy: "://").dropFirst().joined(separator: "://")
        let afterHost = raw.firstIndex(of: "/").map { String(raw[raw.index(after: $0)...]) } ?? ""
        let trimmed = afterHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.removingPercentEncoding ?? trimmed
    }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    public enum Role: String, Codable, Sendable { case inbox, sent, drafts, archive, trash, junk, other }
    public var role: Role {
        if let serverRole { return serverRole }
        let lower = name.lowercased(), full = path.lowercased()
        // Only a top-level Inbox is the inbox, in any case: "INBOX" (IMAP, iCloud, Gmail),
        // "Inbox" (Exchange, Outlook, Yahoo, On My Mac). "Old/Inbox" is an ordinary folder.
        if full == "inbox" { return .inbox }
        if ["sent", "sent messages", "sent items", "sent mail"].contains(lower) { return .sent }
        if ["drafts", "draft", "outbox"].contains(lower) { return .drafts }
        if lower == "archive" || full == "[gmail]/all mail" || lower == "all mail" { return .archive }
        if ["trash", "deleted messages", "deleted items", "bin"].contains(lower) { return .trash }
        if ["junk", "spam", "junk e-mail", "junk email", "bulk mail"].contains(lower) { return .junk }
        return .other
    }
    /// True for mailboxes the All Mail list shows: everything but Trash, Junk, Sent, and Drafts.
    public var inAllMail: Bool { ![.trash, .junk, .sent, .drafts].contains(role) }

    /// The folder that holds this mailbox's messages: each path part gains ".mbox".
    public func folder(in mailRoot: String) -> String {
        let parts = path.split(separator: "/").map { String($0) + ".mbox" }
        return ([mailRoot, accountID] + parts).joined(separator: "/")
    }

    /// The mailbox Mail's scripts should address for a row: the mailbox the list shows (`viewing`)
    /// when the row is in it, then the row's Inbox label, then its own mailbox. For Gmail this makes
    /// Archive and Move take the message out of Inbox, as Mail does.
    public static func actionTarget(for message: MailSummary, viewing: Int64? = nil, in mailboxes: [MailMailbox]) -> MailMailbox? {
        let own = mailboxes.first { $0.rowID == message.mailbox }
        if viewing == message.mailbox { return own }
        if let viewing, message.labels.contains(viewing), let box = mailboxes.first(where: { $0.rowID == viewing }) { return box }
        let inbox = message.labels.lazy.compactMap { id in mailboxes.first { $0.rowID == id && $0.role == .inbox } }.first
        return inbox ?? own
    }

    /// Where the archive for an account lives: its "Archive" mailbox, or Gmail's All Mail.
    public static func archive(for account: String, in mailboxes: [MailMailbox]) -> MailMailbox? {
        let own = mailboxes.filter { $0.accountID == account }
        // A top-level Archive first, then Gmail's All Mail, and never a nested "Clients/Archive" before those.
        return own.first { $0.path.lowercased() == "archive" && $0.role == .archive }
            ?? own.first { $0.path.lowercased() == "[gmail]/all mail" && $0.role == .archive }
            ?? own.filter { $0.role == .archive }.min { $0.path.count < $1.path.count }
    }
}

/// One message row: what the list shows. The body is read later from its `.emlx` file.
public struct MailSummary: Codable, Equatable, Sendable, Identifiable, Hashable {
    public let rowID: Int64
    public var mailbox: Int64
    public let subject: String
    public let senderName: String
    public let senderAddress: String
    public let snippet: String
    public let date: Date
    public var read: Bool
    public var flagged: Bool
    public let conversation: Int64
    /// The same email in two mailboxes, such as Gmail's Inbox and All Mail, has the same key.
    public let messageKey: String
    /// Gmail's label mailboxes for this row, such as its Inbox. The row itself lives in All Mail (`mailbox`).
    public var labels: [Int64] = []
    public init(rowID: Int64, mailbox: Int64, subject: String, senderName: String, senderAddress: String, snippet: String,
                date: Date, read: Bool, flagged: Bool, conversation: Int64, messageKey: String? = nil) {
        self.rowID = rowID; self.mailbox = mailbox; self.subject = subject; self.senderName = senderName; self.senderAddress = senderAddress
        self.snippet = snippet; self.date = date; self.read = read; self.flagged = flagged; self.conversation = conversation
        self.messageKey = messageKey ?? "row:\(rowID)"
    }
    public var id: Int64 { rowID }
    public var sender: String { senderName.isEmpty ? senderAddress : senderName }
    /// Every mailbox that shows this row: its own and its labels.
    public var mailboxes: [Int64] { [mailbox] + labels.filter { $0 != mailbox } }
}

public enum MailFiles {
    /// The newest `V…` folder under `~/Library/Mail`, such as "V10".
    public static func versionFolder(_ names: [String]) -> String? {
        names.filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }.max { Int($0.dropFirst())! < Int($1.dropFirst())! }
    }

    /// Mail files message 123456 under `Data/3/2/1/Messages/123456.emlx`: the digits of
    /// rowID / 1000, last digit first. Messages below 1000 sit in `Data/Messages`.
    public static func relativePaths(rowID: Int64) -> [String] {
        let folder = String(rowID / 1000)
        let digits = folder == "0" ? "" : folder.reversed().map(String.init).joined(separator: "/") + "/"
        let base = "Data/" + digits + "Messages/\(rowID)"
        return [base + ".emlx", base + ".partial.emlx"]
    }
}
