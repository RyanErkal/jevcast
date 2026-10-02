import Foundation

/// Fixed AppleScript. Values are arguments, never executable script text.
public enum MailScripts {
    /// Account, mailbox, index row, and independently read Message-ID must all agree.
    public static let findMessage = """
          if (count of argv) < 4 or (item 4 of argv) is "" then error "The original message has no verified Message-ID." number 1004
          set acct to first account whose id is (item 1 of argv)
          set mb to mailbox (item 2 of argv) of acct
          set mid to (item 3 of argv) as integer
          set m to first message of mb whose id is mid
          set actualID to message id of m
          if actualID starts with "<" and actualID ends with ">" then set actualID to text 2 thru -2 of actualID
          considering case
            if actualID is not (item 4 of argv) then error "The original message changed. Nothing was changed or sent." number 1004
          end considering
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

    public static let setRead = onMessage("      set read status of m to ((item 5 of argv) is \"true\")")
    public static let setFlagged = onMessage("      set flagged status of m to ((item 5 of argv) is \"true\")")
    /// Delete is only a move to the verified Trash destination. It never calls Mail's delete command.
    public static let delete = onMessage("""
          if (item 2 of argv) is (item 5 of argv) then error "This message is already in Trash. Nothing was deleted." number 1004
          move m to mailbox (item 5 of argv) of acct
    """)
    public static let move = onMessage("      move m to mailbox (item 5 of argv) of acct")
    public static let open = onMessage("      open m\n      activate")

    public static let sendingIdentities = """
    on run argv
      with timeout of 15 seconds
        tell application id "com.apple.mail"
          set output to ""
          repeat with a in accounts
            if enabled of a then
              repeat with addressValue in email addresses of a
                set output to output & (id of a) & tab & (addressValue as text) & tab & (full name of a) & linefeed
              end repeat
            end if
          end repeat
          return output
        end tell
      end timeout
    end run
    """

    public static let outboxCount = """
    on run argv
      if not (application id "com.apple.mail" is running) then return -1
      with timeout of 10 seconds
        tell application id "com.apple.mail" to return count of messages of outbox
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
}
