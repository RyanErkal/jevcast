import Foundation
import LauncherCore

/// Reads the complete current source range before applying structured filters. This keeps a
/// match that is older than the first unfiltered index page from being silently omitted.
enum MailFilterLoader {
    struct Result: Sendable {
        let messages: [MailSummary]
        let metadata: [Int64: MailFilterMessageMetadata]
        let conversationHeaders: [Int64: MailConversationHeader]
        let attachments: Set<Int64>
        let metadataUnknownRows: Set<Int64>
        let recipientMetadataUnknownRows: Set<Int64>
        let attachmentMetadataUnknownRows: Set<Int64>
    }

    nonisolated static func read(root: String, query: MailStore.Query, boxes: [MailMailbox], filter: MailFilter,
                                stop: @escaping @Sendable () -> Bool) throws -> Result {
        var pageQuery = query
        pageQuery.limit = MailStore.pageSize
        pageQuery.before = nil
        pageQuery.after = nil
        var found: [MailSummary] = []
        var metadata: [Int64: MailFilterMessageMetadata] = [:]
        var conversationHeaders: [Int64: MailConversationHeader] = [:]
        var attachments: Set<Int64> = []
        var metadataUnknownRows: Set<Int64> = []
        var recipientMetadataUnknownRows: Set<Int64> = []
        var attachmentMetadataUnknownRows: Set<Int64> = []
        var seen: Set<Int64> = []
        while true {
            try Task.checkCancellation()
            if stop() { throw CancellationError() }
            let page = try MailStore.page(root: root, pageQuery, stop: stop)
            let candidates = page.messages.filter { seen.insert($0.rowID).inserted }
            for message in candidates {
                let account = boxes.first { $0.rowID == message.mailbox || message.labels.contains($0.rowID) }?.accountID ?? ""
                // Avoid opening every body for account/folder/date/flag filters. Recipient and
                // attachment filters opt into body reads because their fields are not in the index.
                let detail = filter.requiresBodyMetadata
                    ? boxes.first { $0.rowID == message.mailbox }.flatMap { MailStore.message(root: root, mailbox: $0, rowID: message.rowID) }
                    : nil
                let recipients = detail.flatMap { raw -> [String]? in
                    let values = [raw.header("To"), raw.header("Cc"), raw.header("Bcc")].compactMap { $0 }
                    return values.flatMap { MailAddress.list($0).map(\.address) }
                } ?? []
                metadata[message.rowID] = MailFilterMessageMetadata(accountID: account, recipients: recipients,
                                                                     hasAttachments: detail?.attachments.isEmpty == false,
                                                                     recipientsKnown: detail != nil, attachmentsKnown: detail != nil)
                // A missing body is unknown only for rows that pass the cheap index predicates.
                // Counting unrelated rows would make a filter look incomplete when those rows
                // could never match its account, folder, sender, date, or flag constraints.
                let indexedMatch = filter.matchesIndexedFields(message, metadata: metadata[message.rowID])
                if detail == nil && indexedMatch {
                    if filter.requiresRecipientMetadata { recipientMetadataUnknownRows.insert(message.rowID) }
                    if filter.requiresAttachmentMetadata { attachmentMetadataUnknownRows.insert(message.rowID) }
                    if filter.requiresBodyMetadata { metadataUnknownRows.insert(message.rowID) }
                }
                if let detail {
                    conversationHeaders[message.rowID] = MailConversationHeader(message: detail,
                        providerThreadID: message.conversation != message.rowID ? message.conversation : nil)
                    if !detail.attachments.isEmpty { attachments.insert(message.rowID) }
                }
                if filter.matches(message, metadata: metadata[message.rowID]) { found.append(message) }
            }
            guard page.hasMore, let last = page.last else { break }
            pageQuery.before = last
        }
        return Result(messages: found.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.rowID > rhs.rowID
        }, metadata: metadata, conversationHeaders: conversationHeaders, attachments: attachments,
        metadataUnknownRows: metadataUnknownRows,
        recipientMetadataUnknownRows: recipientMetadataUnknownRows,
        attachmentMetadataUnknownRows: attachmentMetadataUnknownRows)
    }
}

extension MailModel {
    /// Returns the filter's full result count, independent of the visible page.
    var filteredResultCount: Int? { activeFilterRows.map(\.count) }
    var filterIsActive: Bool { !filter.isEmpty }
    var filterMetadataUnknownCount: Int { activeFilterMetadataUnknownRows.count }
    var filterRecipientMetadataUnknownCount: Int { activeFilterRecipientMetadataUnknownRows.count }
    var filterAttachmentMetadataUnknownCount: Int { activeFilterAttachmentMetadataUnknownRows.count }
    var filterCoverageComplete: Bool { !filter.requiresBodyMetadata || filterMetadataUnknownCount == 0 }

    func setFilter(_ newValue: MailFilter) { filter = newValue }
    func clearFilters() {
        guard !filter.isEmpty else { return }
        filter = MailFilter()
    }

    func reloadFiltered(keepSelection: Bool, root: String) {
        let place = queryPlace, search = self.search, filter = self.filter
        let keptIDs = keepSelection ? messages.map(\.rowID) : []
        loadWork?.cancel()
        listStop.stop()
        let stop = StopFlag()
        listStop = stop
        generation += 1
        loadingMore = false; refreshing = false; reloading = true
        bodySearch = .off; bodyCursor = nil
        activeFilterRows = nil; activeFilterMetadata.removeAll(); activeFilterMetadataUnknownRows.removeAll()
        activeFilterRecipientMetadataUnknownRows.removeAll(); activeFilterAttachmentMetadataUnknownRows.removeAll()
        activeFilterOffset = 0
        let generation = self.generation
        let boxesForQuery = mailboxes
        let query = Self.filteredQuery(place: place, search: search, boxes: boxesForQuery, filter: filter)
        loadWork = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try? MailFilterLoader.read(root: root, query: query, boxes: boxesForQuery, filter: filter, stop: { stop.check() })
            }.value
            guard let self, !stop.isStopped, self.generation == generation else { return }
            self.reloading = false
            guard let result else {
                self.fingerprint = ""
                self.banner = "Mail's filtered index could not be read. Try again in a moment."
                return
            }
            self.activeFilterRows = result.messages
            self.activeFilterMetadata = result.metadata
            self.activeFilterMetadataUnknownRows = result.metadataUnknownRows
            self.activeFilterRecipientMetadataUnknownRows = result.recipientMetadataUnknownRows
            self.activeFilterAttachmentMetadataUnknownRows = result.attachmentMetadataUnknownRows
            self.conversationHeaders.merge(result.conversationHeaders) { _, newer in newer }
            self.conversationAttachments.formUnion(result.attachments)
            let first = Array(result.messages.prefix(MailStore.pageSize))
            self.activeFilterOffset = first.count
            self.hasMore = first.count < result.messages.count
            self.top = first.first.map(MailStore.Cursor.init)
            self.bottom = first.last.map(MailStore.Cursor.init)
            self.mailboxes = boxesForQuery
            // Keep a selected row only when it still passes the new filter.
            let kept = Set(keptIDs).intersection(Set(result.messages.map(\.rowID)))
            self.selectedMessageIDs = self.selectedMessageIDs.intersection(Set(result.messages.map(\.rowID)))
            self.install(first)
            if let previous = self.selectedID, kept.contains(previous) { self.select(previous, byUser: false) }
        }
    }

    func loadNextFilteredPage() {
        guard !reloading, let all = activeFilterRows, activeFilterOffset < all.count else {
            hasMore = false
            return
        }
        let next = Array(all[activeFilterOffset..<min(activeFilterOffset + MailStore.pageSize, all.count)])
        activeFilterOffset += next.count
        hasMore = activeFilterOffset < all.count
        bottom = next.last.map(MailStore.Cursor.init) ?? bottom
        install(MailModel.merge(messages, next, query: .init(mailboxes: [], rowIDs: next.map(\.rowID))))
    }

    nonisolated static func filteredQuery(place: MailModel.Place, search: String, boxes: [MailMailbox], filter: MailFilter) -> MailStore.Query {
        var query = MailModel.query(place, search, boxes)
        if !filter.accountIDs.isEmpty {
            query.mailboxes = query.mailboxes.filter { id in boxes.first(where: { $0.rowID == id }).map { filter.accountIDs.contains($0.accountID) } ?? false }
        }
        if !filter.mailboxIDs.isEmpty { query.mailboxes = query.mailboxes.filter { filter.mailboxIDs.contains($0) } }
        return query
    }
}
