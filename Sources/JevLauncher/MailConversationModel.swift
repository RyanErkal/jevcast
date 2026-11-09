import Foundation
import LauncherCore

extension MailModel {
    /// The currently loaded page grouped by provider thread or Message-ID references.
    /// A subject is never used as a conversation key.
    var conversationGroups: [MailConversation] {
        if let conversationCache { return conversationCache }
        let accounts = mailboxIndex.mapValues(\.accountID)
        let groups = MailConversationGrouping.group(messages, accountID: { message in
            accounts[message.mailbox] ?? message.labels.lazy.compactMap { accounts[$0] }.first ?? ""
        }, headers: conversationHeaders, attachments: conversationAttachments)
        conversationCache = groups
        return groups
    }

    /// True when the list on screen holds mail of more than one account.
    var showsAccountMarks: Bool {
        guard accountCount > 1 else { return false }
        switch place {
        case .inbox, .allMail, .unread, .flagged, .sent, .drafts: return true
        case .outbox, .mailbox: return searchScope == .allAccounts && !search.isEmpty
        }
    }

    func accountMark(_ accountID: String) -> MailAccountMark? {
        accountID.isEmpty ? nil : MailAccountMark(title: accountTitle(accountID), color: MailAccountMark.color(for: accountID))
    }

    var selectedConversation: MailConversation? {
        guard let selectedID else { return nil }
        return conversationGroups.first { $0.messages.contains { $0.summary.rowID == selectedID } }
    }

    /// Rows without a provider conversation key and without a cached MIME header remain
    /// standalone. This count makes the partial reference-graph coverage inspectable.
    var conversationMetadataUnknownCount: Int {
        messages.reduce(into: 0) { count, message in
            if message.conversation == message.rowID && conversationHeaders[message.rowID] == nil { count += 1 }
        }
    }

    var selectedConversationRowID: Int64? { selectedConversation?.latest.summary.rowID }

    var selectedConversationRowIDs: Set<Int64> {
        Set(conversationGroups.compactMap { conversation in
            conversation.messages.contains { selectedMessageIDs.contains($0.summary.rowID) }
                ? conversation.latest.summary.rowID : nil
        })
    }

    func selectConversationRows(_ ids: Set<Int64>) {
        let members = conversationGroups.filter { ids.contains($0.latest.summary.rowID) }
            .flatMap { $0.messages.map(\.summary.rowID) }
        setSelectedMessageIDs(Set(members))
    }

    /// Metadata is retained only for messages whose body was actually read. It can refine
    /// fallback reference grouping and attachment badges without loading every body.
    func rememberConversationMetadata(_ message: MailSummary, detail: MIMEMessage, providerThreadID: Int64? = nil) {
        conversationHeaders[message.rowID] = MailConversationHeader(message: detail,
                                                                       providerThreadID: providerThreadID ?? (message.conversation != message.rowID ? message.conversation : nil))
        if !detail.attachments.isEmpty { conversationAttachments.insert(message.rowID) }
    }
}
