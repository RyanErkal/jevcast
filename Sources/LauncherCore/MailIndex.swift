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
    public init(rowID: Int64, url: String, unread: Int, total: Int, serverRole: Role? = nil) {
        self.rowID = rowID; self.url = url; self.unread = unread; self.total = total; self.serverRole = serverRole
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

    public enum Role: String, Sendable { case inbox, sent, drafts, archive, trash, junk, other }
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
        return own.first { $0.path.lowercased() == "archive" }
            ?? own.first { $0.path.lowercased() == "[gmail]/all mail" }
            ?? own.filter { $0.role == .archive }.min { $0.path.count < $1.path.count }
    }
}

/// One message row: what the list shows. The body is read later from its `.emlx` file.
public struct MailSummary: Equatable, Sendable, Identifiable, Hashable {
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

    /// The text that goes to Mail: `text` without leading spaces and blank lines, so Mail's copy
    /// starts with the same characters as `checkText`.
    public static func sendingText(_ text: String) -> String {
        String(text.drop { $0.isWhitespace })
    }

    /// The first 200 characters of `sendingText`. The reply, forward, and send scripts check that
    /// Mail's copy starts with them before they send.
    public static func checkText(_ text: String) -> String {
        String(sendingText(text).prefix(200))
    }

    /// Reads the text back from `message` and discards it before sending when Mail did not keep it:
    /// Mail can ignore text set on a message it has not shown. Argument `argument` holds `checkText`;
    /// an empty one skips the check. Mail's copy must start with it, so a quoted original that contains
    /// the same words does not count. White space is ignored, because Mail can change line endings and
    /// blank lines; case counts. `before` names Mail's own text from before the change. When that
    /// already starts with the check text, such as the signature "Thanks, Ryan" under the reply
    /// "Thanks", only a copy that no longer starts with Mail's own text shows that the text was kept.
    static func keepsText(_ message: String, argument: Int, before: String? = nil) -> String {
        let check = "(item \(argument) of argv)"
        let own = before.map { "\n            if kept and \($0) starts with \(check) then set kept to written does not start with \($0)" } ?? ""
        return """
              if \(check) is not "" then
                set kept to false
                repeat 10 times
                  set written to (content of \(message)) as text
                  considering case but ignoring white space
                    set kept to written starts with \(check)\(own)
                  end considering
                  if kept then exit repeat
                  delay 0.2
                end repeat
                if not kept then
        \(discard(message))
                  error "Mail did not take the text, so nothing was sent." number 1003
                end if
              end if
        """
    }

    /// Closes `message` without saving, so a message that was not sent does not stay in Mail.
    static func discard(_ message: String) -> String {
        """
                try
                  close \(message) saving no
                end try
                try
                  delete \(message)
                end try
        """
    }

    /// `argv` 4: "true" or "false".
    public static let setRead = onMessage("      set read status of m to ((item 4 of argv) is \"true\")")
    public static let setFlagged = onMessage("      set flagged status of m to ((item 4 of argv) is \"true\")")
    public static let delete = onMessage("      delete m")
    /// `argv` 4: the destination mailbox path in the same account.
    public static let move = onMessage("      move m to mailbox (item 4 of argv) of acct")
    /// `argv` 4: the reply text (`sendingText`); 5: "true" to reply to all; 6: `checkText` of the
    /// reply. The quoted original stays below the text.
    public static let reply = onMessage("""
          set r to reply m opening window false reply to all ((item 5 of argv) is "true")
          set quoted to ""
          repeat 10 times
            delay 0.2
            set quoted to (content of r) as text
            if quoted is not "" then exit repeat
          end repeat
          if quoted is "" then
            set content of r to (item 4 of argv)
          else
            set content of r to (item 4 of argv) & return & return & quoted
          end if
    \(keepsText("r", argument: 6, before: "quoted"))
          if not (send r) then error "Mail did not send the message." number 1002
    """)
    /// `argv` 4: the text above the forwarded message (`sendingText`); 5: recipient addresses, one
    /// per line; 6: `checkText` of the text.
    public static let forward = onMessage("""
          set f to forward m opening window false
          delay 0.5
          repeat with a in paragraphs of (item 5 of argv)
            if (a as text) is not "" then make new to recipient at end of to recipients of f with properties {address:(a as text)}
          end repeat
          -- The body is left as Mail made it when there is no text to add, so attachments stay.
          if (item 4 of argv) is not "" then
            -- Mail fills in the forwarded message a moment after it makes the forward.
            set quoted to ""
            repeat 10 times
              set quoted to (content of f) as text
              if quoted is not "" then exit repeat
              delay 0.2
            end repeat
            set content of f to (item 4 of argv) & return & return & quoted
          end if
    \(keepsText("f", argument: 6, before: "quoted"))
          if not (send f) then error "Mail did not send the message." number 1002
    """)

    /// `argv`: to (one per line), cc (one per line), subject, body (`sendingText`), `checkText` of the body.
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
    \(keepsText("o", argument: 5))
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

    /// `argv`: account IDs. Asks Mail to send pending changes, such as read status, to each server now.
    /// An account that cannot sync, such as one that is offline, does not stop the others.
    public static let synchronize = """
    on run argv
      with timeout of 20 seconds
        tell application id "com.apple.mail"
          repeat with a in argv
            try
              synchronize with (first account whose id is (a as text))
            end try
          end repeat
        end tell
      end timeout
    end run
    """

    /// Opens the message in Mail itself.
    public static let open = onMessage("      open m\n      activate")
}
