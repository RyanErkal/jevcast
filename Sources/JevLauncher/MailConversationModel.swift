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
        conversationIndex = MailConversationIndex(groups)
        conversationRevision &+= 1
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

    /// The mark of each account in `groups`, only when the list really holds mail of more than
    /// one account. Empty otherwise, so a list of one account shows no marks.
    func accountMarks(for groups: [MailConversation]) -> [String: MailAccountMark] {
        guard showsAccountMarks else { return [:] }
        let present = Set(groups.map(\.accountID).filter { !$0.isEmpty })
        guard present.count > 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: present.map { id in
            (id, MailAccountMark(title: accountTitle(id), color: MailAccountMark.color(for: id)))
        })
    }

    var selectedConversation: MailConversation? {
        guard let selectedID else { return nil }
        return conversation(containing: selectedID)
    }

    /// The conversation a message belongs to, by its row ID, without a search of the list.
    func conversation(containing messageID: Int64) -> MailConversation? {
        let groups = conversationGroups
        return conversationIndex.byMessage[messageID].map { groups[$0] }
    }

    /// Rows without a provider conversation key and without a cached MIME header remain
    /// standalone. This count makes the partial reference-graph coverage inspectable.
    var conversationMetadataUnknownCount: Int {
        messages.reduce(into: 0) { count, message in
            if message.conversation == message.rowID && conversationHeaders[message.rowID] == nil { count += 1 }
        }
    }

    /// The selected conversation when it has more than one message: the reader shows it as one document.
    var shownThread: MailConversation? {
        selectedConversation.flatMap { $0.messages.count > 1 ? $0 : nil }
    }

    /// True while the conversation on screen shows every reply's quoted text.
    var quotesShown: Bool { shownThread.map { quotesShownIn == $0.id } ?? false }

    /// Show Quoted Text or Hide Quoted Text, for the conversation on screen.
    func toggleQuotedText() {
        guard let thread = shownThread else { return }
        quotesShownIn = quotesShownIn == thread.id ? nil : thread.id
    }

    var selectedConversationRowID: Int64? { selectedConversation?.latest.summary.rowID }

    var selectedConversationRowIDs: Set<Int64> {
        Set(selectedMessageIDs.compactMap { conversation(containing: $0)?.latest.summary.rowID })
    }

    func selectConversationRows(_ ids: Set<Int64>) {
        let members = ids.compactMap { conversation(row: $0) }.flatMap { $0.messages.map(\.summary.rowID) }
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
