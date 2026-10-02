import Foundation

extension MailScripts {
    public static func sendingText(_ text: String) -> String { String(text.drop { $0.isWhitespace }) }
    public static func checkText(_ text: String) -> String { String(sendingText(text).prefix(200)) }

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
                if not kept then error "Mail did not take the text, so nothing was sent." number 1003
              end if
        """
    }

    /// Only the outgoing object created by this script can be closed. Received mail is never deleted.
    static func discard(_ message: String) -> String {
        """
                try
                  close \(message) saving no
                end try
        """
    }

    static func sender(_ message: String, account: Int, address: Int) -> String {
        """
          set sendingAccount to first account whose id is (item \(account) of argv)
          if not (enabled of sendingAccount) or (item \(address) of argv) is not in (email addresses of sendingAccount) then error "The sending account is not available." number 1004
          set sender of \(message) to (item \(address) of argv)
          set chosenSender to sender of \(message)
          if chosenSender is not (item \(address) of argv) and chosenSender does not end with ("<" & (item \(address) of argv) & ">") then error "Mail did not keep the sending address." number 1003
        """
    }

    static func attachments(_ message: String, argument: Int) -> String {
        """
          repeat with filePath in paragraphs of (item \(argument) of argv)
            if (filePath as text) is not "" then
              set selectedFile to (POSIX file (filePath as text)) as alias
              tell content of \(message) to make new attachment with properties {file name:selectedFile} at after last paragraph
            end if
          end repeat
        """
    }

    /// Insert into the rich text object. Do not replace the quoted content with its text coercion.
    static func insert(_ message: String, argument: Int) -> String {
        """
          set quoted to ""
          set sourceText to (content of m) as text
          if (length of sourceText) > 80 then set sourceText to text 1 thru 80 of sourceText
          set readyToWrite to false
          repeat 20 times
            delay 0.2
            set quoted to (content of \(message)) as text
            considering case but ignoring white space
              set readyToWrite to sourceText is "" or quoted contains sourceText
            end considering
            if readyToWrite then exit repeat
          end repeat
          if not readyToWrite then error "Mail did not finish the quoted message. Nothing was sent." number 1003
          if (item \(argument) of argv) is not "" then
            tell content of \(message) to make new paragraph at beginning with data ((item \(argument) of argv) & return & return)
          end if
        """
    }

    static func sending(_ message: String, prepare: String, check argument: Int, before: String? = nil) -> String {
        """
        on run argv
          with timeout of 20 seconds
            tell application id "com.apple.mail"
              try
        \(prepare)
        \(keepsText(message, argument: argument, before: before))
              on error errText number errNum
        \(discard(message))
                if errNum is -1743 or errNum is 1003 then error errText number errNum
                error errText number 1004
              end try
              try
                set didSend to (send \(message))
              on error
                error "Mail stopped while it sent the message." number 1005
              end try
              if not didSend then
        \(discard(message))
                error "Mail did not send the message." number 1002
              end if
            end tell
          end timeout
        end run
        """
    }

    /// Arguments: account, mailbox, row, Message-ID, text, reply-all, check, sender account/address, selected files.
    public static let reply = sending("r", prepare: """
    \(findMessage)
          set r to reply m opening window false reply to all ((item 6 of argv) is "true")
    \(sender("r", account: 8, address: 9))
    \(insert("r", argument: 5))
    \(attachments("r", argument: 10))
    """, check: 7, before: "quoted")

    /// Arguments: account, mailbox, row, Message-ID, text, recipients, check, sender account/address, selected files.
    public static let forward = sending("f", prepare: """
    \(findMessage)
          set f to forward m opening window false
    \(sender("f", account: 8, address: 9))
          repeat with a in paragraphs of (item 6 of argv)
            if (a as text) is not "" then make new to recipient at end of to recipients of f with properties {address:(a as text)}
          end repeat
    \(insert("f", argument: 5))
    \(attachments("f", argument: 10))
    """, check: 7, before: "quoted")

    /// Arguments: To, Cc, subject, text, check, sender account/address, selected files.
    public static let send = sending("o", prepare: """
          set o to make new outgoing message with properties {subject:(item 3 of argv), content:(item 4 of argv), visible:false}
    \(sender("o", account: 6, address: 7))
          repeat with a in paragraphs of (item 1 of argv)
            if (a as text) is not "" then make new to recipient at end of to recipients of o with properties {address:(a as text)}
          end repeat
          repeat with a in paragraphs of (item 2 of argv)
            if (a as text) is not "" then make new cc recipient at end of cc recipients of o with properties {address:(a as text)}
          end repeat
    \(attachments("o", argument: 8))
    """, check: 5)
}
