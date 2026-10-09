import Foundation
import LauncherCore

extension MailModel {
    /// The currently loaded page grouped by provider thread or Message-ID references.
    /// A subject is never used as a conversation key.
    var conversationGroups: [MailConversation] {
        MailConversationGrouping.group(messages, accountID: { message in
            mailbox(message.mailbox)?.accountID ?? mailboxes.first { message.labels.contains($0.rowID) }?.accountID ?? ""
        }, headers: conversationHeaders, attachments: conversationAttachments)
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
