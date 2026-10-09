import Foundation

/// Header identity used to build conversations without relying on a subject line.
/// Provider thread IDs are authoritative when present. Message-ID references are the
/// fallback for providers that do not expose a thread ID.
public struct MailConversationHeader: Sendable, Equatable, Hashable {
    public let providerThreadID: Int64?
    public let messageID: String?
    public let references: [String]
    public let inReplyTo: String?

    public init(providerThreadID: Int64? = nil, messageID: String? = nil,
                references: [String] = [], inReplyTo: String? = nil) {
        self.providerThreadID = providerThreadID
        self.messageID = Self.normalise(messageID)
        self.references = references.compactMap(Self.normalise)
        self.inReplyTo = Self.normalise(inReplyTo)
    }

    public init(message: MIMEMessage, providerThreadID: Int64? = nil) {
        self.init(providerThreadID: providerThreadID,
                  messageID: message.header("Message-ID"),
                  references: MailReplies.messageIDs(message.header("References") ?? "") ?? [],
                  inReplyTo: (MailReplies.messageIDs(message.header("In-Reply-To") ?? "") ?? []).first)
    }

    /// Header IDs are case-insensitive in practice. Keep angle brackets so a token
    /// that happens to contain whitespace cannot join unrelated messages.
    public static func normalise(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !cleaned.isEmpty, !cleaned.contains(where: { $0.isWhitespace }) else { return nil }
        return "<" + cleaned.lowercased() + ">"
    }

    public var relatedIDs: [String] { references + [inReplyTo].compactMap { $0 } }
}

/// A message with the account boundary and the header information needed for grouping.
public struct MailConversationMessage: Sendable, Equatable, Hashable {
    public let summary: MailSummary
    public let accountID: String
    public let header: MailConversationHeader
    public let hasAttachments: Bool

    public init(summary: MailSummary, accountID: String, header: MailConversationHeader = .init(), hasAttachments: Bool = false) {
        self.summary = summary
        self.accountID = accountID
        self.header = header
        self.hasAttachments = hasAttachments
    }
}

/// Stable, account-scoped conversation identity. An account is always part of the key,
/// so identical provider thread numbers can never merge across accounts.
public struct MailConversationID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let accountID: String
    public let value: String

    public init(accountID: String, value: String) {
        self.accountID = accountID
        self.value = value
    }

    public var description: String { accountID + ":" + value }
}

/// A grouped set of messages. Messages are newest first for list display.
public struct MailConversation: Sendable, Equatable, Hashable, Identifiable {
    public let id: MailConversationID
    public let accountID: String
    public let messages: [MailConversationMessage]

    public var stableID: String { id.description }
    public var latest: MailConversationMessage { messages[0] }
    public var subject: String { latest.summary.subject }
    public var unreadCount: Int { messages.reduce(into: 0) { if !$1.summary.read { $0 += 1 } } }
    public var hasUnread: Bool { unreadCount > 0 }
    public var isFlagged: Bool { messages.contains { $0.summary.flagged } }
    public var hasAttachments: Bool { messages.contains { $0.hasAttachments } }

    public init(id: MailConversationID, accountID: String, messages: [MailConversationMessage]) {
        self.id = id
        self.accountID = accountID
        self.messages = messages.sorted { lhs, rhs in
            if lhs.summary.date != rhs.summary.date { return lhs.summary.date > rhs.summary.date }
            return lhs.summary.rowID > rhs.summary.rowID
        }
    }
}

public enum MailConversationGrouping {
    /// Groups without ever comparing subjects. A provider thread ID groups only within
    /// one account. Otherwise connected Message-ID references form a thread.
    public static func group(_ messages: [MailConversationMessage]) -> [MailConversation] {
        guard !messages.isEmpty else { return [] }
        var parent = Array(messages.indices)
        // Track provider identities per component. A cached reference header must never bridge
        // two provider threads just because an intermediate message has no thread ID.
        var providerIDs = Array(repeating: Set<Int64>(), count: messages.count)
        for (index, item) in messages.enumerated() {
            if let thread = item.header.providerThreadID { providerIDs[index].insert(thread) }
        }
        func find(_ value: Int) -> Int {
            var value = value
            while parent[value] != value {
                parent[value] = parent[parent[value]]
                value = parent[value]
            }
            return value
        }
        @discardableResult
        func join(_ left: Int, _ right: Int) -> Bool {
            let a = find(left), b = find(right)
            guard a != b else { return true }
            guard providerIDs[a].isEmpty || providerIDs[b].isEmpty || providerIDs[a] == providerIDs[b] else {
                return false
            }
            parent[b] = a
            providerIDs[a].formUnion(providerIDs[b])
            return true
        }

        func scopedAccount(_ item: MailConversationMessage, index: Int) -> String {
            let account = item.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            // An unknown account is not a safe shared scope. Keep each such row isolated until
            // the mailbox metadata resolves, rather than risking a cross-account thread.
            return account.isEmpty ? "\u{0}unknown:\(index)" : account.lowercased()
        }
        func scopedKey(account: String, value: String) -> String { account + "\u{1F}" + value }
        var provider: [String: [Int]] = [:]
        var messageIDs: [String: [Int]] = [:]
        var referencedIDs: [String: [Int]] = [:]
        for (index, item) in messages.enumerated() {
            let account = scopedAccount(item, index: index)
            if let thread = item.header.providerThreadID {
                provider[scopedKey(account: account, value: String(thread)), default: []].append(index)
            }
            if let messageID = item.header.messageID {
                messageIDs[scopedKey(account: account, value: messageID), default: []].append(index)
            }
            for related in item.header.relatedIDs {
                referencedIDs[scopedKey(account: account, value: related), default: []].append(index)
            }
        }

        // Provider IDs and duplicate Message-IDs are exact identities. Reference edges are
        // considered below, after these components establish their provider identities.
        for indices in provider.values {
            guard let first = indices.first else { continue }
            for index in indices.dropFirst() { _ = join(first, index) }
        }
        for indices in messageIDs.values {
            guard let first = indices.first else { continue }
            for index in indices.dropFirst() { _ = join(first, index) }
        }

        // Exclude ambiguous fallback rows from both ends of an edge. Otherwise an earlier
        // provider row could absorb the bridge before the bridge itself is inspected.
        let ambiguous = Set(messages.indices.filter { index in
            let item = messages[index]
            guard item.header.providerThreadID == nil else { return false }
            let account = scopedAccount(item, index: index)
            let related = item.header.relatedIDs.flatMap { id -> [Int] in
                let key = scopedKey(account: account, value: id)
                return (messageIDs[key] ?? []) + (referencedIDs[key] ?? [])
            }
            return Set(related.compactMap { messages[$0].header.providerThreadID }).count > 1
        })

        // An explicit reference can join a cached-header fallback to a provider thread. If the
        // same row points at more than one provider thread, leave it standalone rather than
        // guessing which thread owns it. This is intentionally independent of subject text.
        for (index, item) in messages.enumerated() {
            let account = scopedAccount(item, index: index)
            var relatedIndices = Set<Int>()
            for related in item.header.relatedIDs {
                let key = scopedKey(account: account, value: related)
                relatedIndices.formUnion(messageIDs[key] ?? [])
                relatedIndices.formUnion(referencedIDs[key] ?? [])
            }
            guard !ambiguous.contains(index) else { continue }
            relatedIndices.subtract(ambiguous)
            relatedIndices.remove(index)
            let relatedProviderIDs = Set(relatedIndices.compactMap { messages[$0].header.providerThreadID })
            guard relatedProviderIDs.count <= 1 else { continue }
            for old in relatedIndices.sorted() { _ = join(index, old) }
        }

        var buckets: [Int: [MailConversationMessage]] = [:]
        for index in messages.indices { buckets[find(index), default: []].append(messages[index]) }
        return buckets.values.compactMap { group in
            guard let first = group.first else { return nil }
            let threads = Set(group.compactMap { $0.header.providerThreadID })
            let value: String
            if let thread = threads.sorted().first {
                value = "provider:" + String(thread)
            } else {
                let references = group.flatMap { $0.header.relatedIDs }.sorted()
                let messageIDs = group.compactMap { $0.header.messageID }.sorted()
                if let root = references.first ?? messageIDs.first {
                    value = "reference:" + root
                } else {
                    // No identity means this is a singleton. The row ID is not a subject-based
                    // fallback and cannot accidentally join another message.
                    value = "row:" + String(first.summary.rowID)
                }
            }
            let conversationAccount = first.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\u{0}unknown:\(first.summary.rowID)" : first.accountID
            return MailConversation(id: MailConversationID(accountID: conversationAccount, value: value),
                                   accountID: first.accountID, messages: group)
        }.sorted { lhs, rhs in
            if lhs.latest.summary.date != rhs.latest.summary.date { return lhs.latest.summary.date > rhs.latest.summary.date }
            return lhs.latest.summary.rowID > rhs.latest.summary.rowID
        }
    }

    public static func group(_ summaries: [MailSummary], accountID: (MailSummary) -> String,
                             headers: [Int64: MailConversationHeader] = [:],
                             attachments: Set<Int64> = []) -> [MailConversation] {
        group(summaries.map { summary in
            MailConversationMessage(summary: summary, accountID: accountID(summary),
                                    header: headers[summary.rowID] ?? MailConversationHeader(
                                        // A non-row conversation value is the provider's thread key
                                        // already carried by the index.
                                        providerThreadID: summary.conversation != summary.rowID ? summary.conversation : nil),
                                    hasAttachments: attachments.contains(summary.rowID))
        })
    }
}
