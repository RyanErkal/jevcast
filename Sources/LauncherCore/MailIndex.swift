import Foundation

/// A mailbox from Apple Mail's `Envelope Index`, such as `imap://<account>/INBOX`.
public struct MailMailbox: Equatable, Sendable, Identifiable, Hashable {
    public let rowID: Int64
    public let url: String
    public let unread: Int
    public let total: Int
    public init(rowID: Int64, url: String, unread: Int, total: Int) {
        self.rowID = rowID; self.url = url; self.unread = unread; self.total = total
    }
    public var id: Int64 { rowID }

    /// The account's ID: the URL host, which is also the folder name under `~/Library/Mail/V…`.
    public var accountID: String { URL(string: url)?.host ?? "" }
    /// The path Mail's AppleScript uses for the mailbox, such as "INBOX" or "[Gmail]/All Mail".
    public var path: String {
        let raw = url.components(separatedBy: "://").dropFirst().joined(separator: "://")
        let afterHost = raw.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        return afterHost.removingPercentEncoding ?? afterHost
    }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    public enum Role: Sendable { case inbox, sent, drafts, archive, trash, junk, other }
    public var role: Role {
        let lower = name.lowercased(), full = path.lowercased()
        // Only the top-level Inbox is the inbox; "Old/Inbox" is an ordinary folder.
        if full == "inbox" { return .inbox }
        if ["sent", "sent messages", "sent items", "sent mail"].contains(lower) { return .sent }
        if lower == "drafts" { return .drafts }
        if lower == "archive" || full == "[gmail]/all mail" || lower == "all mail" { return .archive }
        if ["trash", "deleted messages", "deleted items", "bin"].contains(lower) { return .trash }
        if ["junk", "spam", "junk e-mail", "junk email"].contains(lower) { return .junk }
        return .other
    }

    /// The folder that holds this mailbox's messages: each path part gains ".mbox".
    public func folder(in mailRoot: String) -> String {
        let parts = path.split(separator: "/").map { String($0) + ".mbox" }
        return ([mailRoot, accountID] + parts).joined(separator: "/")
    }

    /// Where the archive for an account lives: its "Archive" mailbox, or Gmail's All Mail.
    public static func archive(for account: String, in mailboxes: [MailMailbox]) -> MailMailbox? {
        let own = mailboxes.filter { $0.accountID == account }
        // A top-level Archive first, then Gmail's All Mail, and never a nested "Clients/Archive" before those.
        return own.first { $0.path.lowercased() == "archive" }
            ?? own.first { $0.path.lowercased() == "[gmail]/all mail" }
            ?? own.filter { $0.role == .archive }.min { $0.path.count < $1.path.count }
    }
}

/// One message row: what the list shows. The body is read later from its `.emlx` file.
public struct MailSummary: Equatable, Sendable, Identifiable, Hashable {
    public let rowID: Int64
    public let mailbox: Int64
    public let subject: String
    public let senderName: String
    public let senderAddress: String
    public let snippet: String
    public let date: Date
    public var read: Bool
    public var flagged: Bool
    public let conversation: Int64
    public init(rowID: Int64, mailbox: Int64, subject: String, senderName: String, senderAddress: String, snippet: String,
                date: Date, read: Bool, flagged: Bool, conversation: Int64) {
        self.rowID = rowID; self.mailbox = mailbox; self.subject = subject; self.senderName = senderName; self.senderAddress = senderAddress
        self.snippet = snippet; self.date = date; self.read = read; self.flagged = flagged; self.conversation = conversation
    }
    public var id: Int64 { rowID }
    public var sender: String { senderName.isEmpty ? senderAddress : senderName }
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

/// Fixed AppleScript for Apple Mail. Every value arrives in `argv`: account ID, mailbox path,
/// message ID, and any text. Nothing the user typed or a message contains becomes script text.
public enum MailScripts {
    /// The message `m`, found by account ID, mailbox path, and Mail's message ID (the index row ID).
    public static let findMessage = """
          set acct to first account whose id is (item 1 of argv)
          set mb to mailbox (item 2 of argv) of acct
          -- In Mail's dictionary "message id" is the Message-ID header, so the message is found by its number.
          set mid to (item 3 of argv) as integer
          set m to first message of mb whose id is mid
    """

    static func onMessage(_ body: String) -> String {
        """
        on run argv
          with timeout of 20 seconds
            tell application id "com.apple.mail"
        \(findMessage)
        \(body)
            end tell
          end timeout
        end run
        """
    }

    /// `argv` 4: "true" or "false".
    public static let setRead = onMessage("      set read status of m to ((item 4 of argv) is \"true\")")
    public static let setFlagged = onMessage("      set flagged status of m to ((item 4 of argv) is \"true\")")
    public static let delete = onMessage("      delete m")
    /// `argv` 4: the destination mailbox path in the same account.
    public static let move = onMessage("      move m to mailbox (item 4 of argv) of acct")
    /// `argv` 4: the reply text; 5: "true" to reply to all. The quoted original stays below the text.
    public static let reply = onMessage("""
          set r to reply m opening window false reply to all ((item 5 of argv) is "true")
          set quoted to ""
          repeat 10 times
            delay 0.2
            set quoted to content of r
            if quoted is not "" then exit repeat
          end repeat
          if quoted is "" then
            set content of r to (item 4 of argv)
          else
            set content of r to (item 4 of argv) & return & return & quoted
          end if
          if not (send r) then error "Mail did not send the message." number 1002
    """)
    /// `argv` 4: the text above the forwarded message; 5: recipient addresses, one per line.
    public static let forward = onMessage("""
          set f to forward m opening window false
          delay 0.5
          repeat with a in paragraphs of (item 5 of argv)
            if (a as text) is not "" then make new to recipient at end of to recipients of f with properties {address:(a as text)}
          end repeat
          -- The body is left as Mail made it when there is no text to add, so attachments stay.
          if (item 4 of argv) is not "" then
            set quoted to content of f
            set content of f to (item 4 of argv) & return & return & quoted
          end if
          if not (send f) then error "Mail did not send the message." number 1002
    """)

    /// `argv`: to (one per line), cc (one per line), subject, body.
    public static let send = """
    on run argv
      with timeout of 20 seconds
        tell application id "com.apple.mail"
          set o to make new outgoing message with properties {subject:(item 3 of argv), content:(item 4 of argv), visible:false}
          repeat with a in paragraphs of (item 1 of argv)
            if (a as text) is not "" then make new to recipient at end of to recipients of o with properties {address:(a as text)}
          end repeat
          repeat with a in paragraphs of (item 2 of argv)
            if (a as text) is not "" then make new cc recipient at end of cc recipients of o with properties {address:(a as text)}
          end repeat
          if not (send o) then error "Mail did not send the message." number 1002
        end tell
      end timeout
    end run
    """

    public static let checkForNewMail = """
    on run argv
      with timeout of 10 seconds
        tell application id "com.apple.mail" to check for new mail
      end timeout
    end run
    """

    /// Opens the message in Mail itself.
    public static let open = onMessage("      open m\n      activate")
}
