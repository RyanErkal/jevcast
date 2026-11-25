import Foundation
import LauncherCore

/// Each list row's place in the grouped list, by its row ID and by each message's row ID, so
/// the menus, the selection, and the reader find a conversation without a search of the list.
struct MailConversationIndex {
    /// A list row's ID (its newest message) to its place.
    private(set) var byRow: [Int64: Int] = [:]
    /// Any message's row ID to its conversation's place.
    private(set) var byMessage: [Int64: Int] = [:]

    init() {}

    init(_ groups: [MailConversation]) {
        byRow.reserveCapacity(groups.count)
        for (index, conversation) in groups.enumerated() {
            byRow[conversation.latest.summary.rowID] = index
            for message in conversation.messages { byMessage[message.summary.rowID] = index }
        }
    }
}

/// What the list draws beside its rows: the date labels, the account names, the VIP rows, and
/// the buttons under the pointer. It is worked out once per grouping of the list (and when the
/// place, the day, the VIP senders, or the accounts change), not on every redraw, so typing a
/// draft does not walk the whole mailbox again.
struct MailListMetadata {
    struct Key: Equatable {
        let revision: Int
        let place: MailModel.Place
        let canListMultipleAccounts: Bool
        let titles: [String]
        let vip: Set<String>
        let day: Date
    }

    let key: Key
    let sections: [MailConversationID: MailDateSection]
    let accountTitles: [String: String]
    /// Rows with a message from a VIP sender.
    let vip: Set<Int64>
    /// The buttons under the pointer, by `boxKey`: rows that share a mailbox and labels share them.
    let hover: [[Int64]: [MailRowAction]]

    /// Rows whose actions use the same mailbox: its own and its labels.
    static func boxKey(_ message: MailSummary) -> [Int64] { [message.mailbox] + message.labels }

    func hoverActions(_ message: MailSummary) -> [MailRowAction] { hover[Self.boxKey(message)] ?? [] }
}

extension MailModel {
    /// The list's metadata for the rows on screen, from the cache when nothing it reads changed.
    var listMetadata: MailListMetadata {
        let groups = conversationGroups
        let key = MailListMetadata.Key(revision: conversationRevision, place: place, canListMultipleAccounts: canListMultipleAccounts,
                                       titles: canListMultipleAccounts ? senders.map(\.address) : [], vip: vipAddresses,
                                       day: Calendar.current.startOfDay(for: Date()))
        if let cached = listMetadataCache, cached.key == key { return cached }
        var hover: [[Int64]: [MailRowAction]] = [:]
        var vip = Set<Int64>()
        for conversation in groups {
            let message = conversation.latest.summary
            if place != .outbox {
                let box = MailListMetadata.boxKey(message)
                if hover[box] == nil { hover[box] = MailRowMenu.hoverActions(MailRowMenuContext(roles: [actionBox(message)?.role])) }
            }
            if !vipAddresses.isEmpty, conversation.messages.contains(where: { isVIP($0.summary) }) { vip.insert(message.rowID) }
        }
        let metadata = MailListMetadata(key: key, sections: MailMessageList.sections(groups, place: place),
                                        accountTitles: accountTitles(for: groups), vip: vip, hover: hover)
        listMetadataCache = metadata
        listMetadataBuilds &+= 1
        return metadata
    }
}
