import Foundation

/// The one-click filters above the list. Each sets the same field the filter form sets, at once.
public enum MailFilterChip: String, CaseIterable, Sendable {
    case unread, flagged, attachments

    public var title: String {
        switch self {
        case .unread: return "Unread"
        case .flagged: return "Flagged"
        case .attachments: return "Attachments"
        }
    }

    public func isOn(_ filter: MailFilter) -> Bool {
        switch self {
        case .unread: return filter.unreadOnly
        case .flagged: return filter.flaggedOnly
        case .attachments: return filter.attachmentsOnly
        }
    }

    /// The filter with this chip turned on or off. Every other field stays.
    public func toggled(_ filter: MailFilter) -> MailFilter {
        var next = filter
        switch self {
        case .unread: next.unreadOnly.toggle()
        case .flagged: next.flaggedOnly.toggle()
        case .attachments: next.attachmentsOnly.toggle()
        }
        return next
    }

    /// Filters on that have no chip, such as a sender or a date: the More chip counts them.
    public static func otherCount(_ filter: MailFilter) -> Int {
        filter.activeCount - allCases.filter { $0.isOn(filter) }.count
    }
}
