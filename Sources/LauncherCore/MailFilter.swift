import Foundation

/// Metadata that is not guaranteed to be present in a list index row.
public struct MailFilterMessageMetadata: Sendable, Equatable, Hashable {
    public let accountID: String
    public let recipients: [String]
    public let hasAttachments: Bool
    public let recipientsKnown: Bool
    public let attachmentsKnown: Bool

    public init(accountID: String = "", recipients: [String] = [], hasAttachments: Bool = false,
                recipientsKnown: Bool = true, attachmentsKnown: Bool = true) {
        self.accountID = accountID
        self.recipients = recipients
        self.hasAttachments = hasAttachments
        self.recipientsKnown = recipientsKnown
        self.attachmentsKnown = attachmentsKnown
    }
}

/// Structured mail filters. Empty fields do not filter. Date boundaries are inclusive.
public struct MailFilter: Sendable, Codable, Equatable, Hashable {
    public var accountIDs: Set<String> = []
    public var mailboxIDs: Set<Int64> = []
    public var from = ""
    public var to = ""
    public var dateFrom: Date?
    public var dateTo: Date?
    public var unreadOnly = false
    public var flaggedOnly = false
    public var attachmentsOnly = false

    public init(accountIDs: Set<String> = [], mailboxIDs: Set<Int64> = [], from: String = "", to: String = "",
                dateFrom: Date? = nil, dateTo: Date? = nil, unreadOnly: Bool = false,
                flaggedOnly: Bool = false, attachmentsOnly: Bool = false) {
        self.accountIDs = accountIDs; self.mailboxIDs = mailboxIDs; self.from = from; self.to = to
        self.dateFrom = dateFrom; self.dateTo = dateTo; self.unreadOnly = unreadOnly
        self.flaggedOnly = flaggedOnly; self.attachmentsOnly = attachmentsOnly
    }

    public var isEmpty: Bool {
        accountIDs.isEmpty && mailboxIDs.isEmpty && from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && dateFrom == nil && dateTo == nil
            && !unreadOnly && !flaggedOnly && !attachmentsOnly
    }

    public var activeCount: Int {
        [!accountIDs.isEmpty, !mailboxIDs.isEmpty, !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, dateFrom != nil, dateTo != nil,
         unreadOnly, flaggedOnly, attachmentsOnly].filter { $0 }.count
    }

    public mutating func clear() { self = MailFilter() }

    public func matches(_ message: MailSummary, metadata: MailFilterMessageMetadata? = nil) -> Bool {
        guard matchesIndexedFields(message, metadata: metadata) else { return false }
        if attachmentsOnly {
            guard let metadata, metadata.attachmentsKnown, metadata.hasAttachments else { return false }
        }
        if !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let metadata, metadata.recipientsKnown,
                  metadata.recipients.contains(where: { $0.localizedCaseInsensitiveContains(to.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return false }
        }
        return true
    }

    /// Returns whether a row passes every filter that is available from the list index.
    /// Recipient and attachment predicates are intentionally excluded. Callers use this to
    /// count rows that could become matches once their MIME body is downloaded.
    public func matchesIndexedFields(_ message: MailSummary, metadata: MailFilterMessageMetadata? = nil) -> Bool {
        if !accountIDs.isEmpty {
            guard let metadata, accountIDs.contains(metadata.accountID) else { return false }
        }
        if !mailboxIDs.isEmpty, Set(message.mailboxes).isDisjoint(with: mailboxIDs) { return false }
        if unreadOnly && message.read { return false }
        if flaggedOnly && !message.flagged { return false }
        if let dateFrom, message.date < dateFrom { return false }
        if let dateTo, message.date > dateTo { return false }
        return matches(from, in: [message.senderAddress, message.senderName])
    }

    public var requiresRecipientMetadata: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var requiresAttachmentMetadata: Bool { attachmentsOnly }

    /// A short, explicit explanation suitable for the filter editor and list tools.
    public var bodyMetadataCoverageDescription: String {
        switch (requiresRecipientMetadata, requiresAttachmentMetadata) {
        case (true, true): return "To and attachment filters match downloaded message bodies only."
        case (true, false): return "The To filter matches downloaded message bodies only."
        case (false, true): return "The attachment filter matches downloaded message bodies only."
        case (false, false): return ""
        }
    }

    private func matches(_ query: String, in values: [String]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    public var requiresBodyMetadata: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentsOnly
    }
}

/// Filtering is deliberately performed before the page slice. This helper is also used by
/// tests and by the launcher loader after it has read the complete matching source range.
public enum MailFilterPaging {
    public static func filter(_ messages: [MailSummary], by filter: MailFilter,
                              metadata: [Int64: MailFilterMessageMetadata] = [:]) -> [MailSummary] {
        messages.filter { filter.matches($0, metadata: metadata[$0.rowID]) }.sorted {
            $0.date == $1.date ? $0.rowID > $1.rowID : $0.date > $1.date
        }
    }

    public static func page(_ messages: [MailSummary], filter: MailFilter, offset: Int, limit: Int,
                            metadata: [Int64: MailFilterMessageMetadata] = [:]) -> ArraySlice<MailSummary> {
        let filtered = MailFilterPaging.filter(messages, by: filter, metadata: metadata)
        guard offset >= 0, offset < filtered.count, limit > 0 else { return filtered[0..<0] }
        return filtered[offset..<min(offset + limit, filtered.count)]
    }
}
