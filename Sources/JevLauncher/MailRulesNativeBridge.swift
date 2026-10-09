import Foundation
import LauncherCore

/// Current native identity used by a rule action. The root refreshes these values from its mail
/// model before every action, so a deleted, moved, or changed message cannot be acted on silently.
struct MailRuleNativeTarget: Sendable {
    let summary: MailSummary
    let mailbox: MailMailbox
}

enum MailRulesNativeBridge {
    static func observation(summary: MailSummary, mailbox: MailMailbox) -> MailRuleMessage {
        MailRuleMessage(id: MailRuleMessage.nativeID(accountID: mailbox.accountID, mailboxID: mailbox.rowID, rowID: summary.rowID),
                        accountID: mailbox.accountID, mailboxID: mailbox.rowID, mailboxPath: mailbox.path,
                        from: summary.senderAddress, subject: summary.subject, receivedAt: summary.date,
                        isRead: summary.read, isFlagged: summary.flagged)
    }

    static func notification(summary: MailSummary, mailbox: MailMailbox) -> MailNotificationMessage {
        let identity: String
        if summary.messageKey.isEmpty || summary.messageKey.hasPrefix("row:") {
            identity = MailRuleMessage.nativeID(accountID: mailbox.accountID, mailboxID: mailbox.rowID, rowID: summary.rowID)
        } else {
            identity = "native-message:\(mailbox.accountID):\(summary.messageKey)"
        }
        return MailNotificationMessage(id: identity, accountID: mailbox.accountID, sender: summary.sender,
                                       subject: summary.subject, receivedAt: summary.date, isRead: summary.read)
    }

    /// Root supplies a lookup from the stable observation ID to the current `MailSummary` and
    /// source mailbox, plus a current folder lookup. The existing native action APIs then perform
    /// their Message-ID/subject/from and account checks at the last possible moment.
    static func executor(current: @escaping @Sendable (String) -> MailRuleNativeTarget?,
                         folder: @escaping @Sendable (String, Int64, String) -> MailMailbox?) -> MailRuleEngine.ActionExecutor {
        { action, observed in
            guard let target = current(observed.id) else {
                throw MailRuleExecutionError.needsReview("This message changed or is no longer available. Review the rule match.")
            }
            switch action {
            case .markRead(let value):
                try await MailActions.setRead(value, target.summary, in: target.mailbox)
            case .markFlagged(let value):
                try await MailActions.setFlagged(value, target.summary, in: target.mailbox)
            case let .moveToFolder(accountID, mailboxID, path):
                guard target.mailbox.accountID == accountID,
                      let destination = folder(accountID, mailboxID, path), destination.accountID == accountID,
                      destination.rowID == mailboxID, destination.path == path else {
                    throw MailRuleExecutionError.needsReview("The selected folder changed. Choose the current folder and review this match.")
                }
                try await MailActions.move(target.summary, from: target.mailbox, to: destination)
            }
        }
    }
}
