import Foundation

/// Folder paths are already normalized to slash-separated parts by each mail source.
public struct MailboxTree: Sendable, Equatable, Identifiable {
    public let accountID: String
    public let path: String
    public let title: String
    public var mailbox: MailMailbox?
    public var children: [MailboxTree]
    public var id: String { accountID + ":" + path }

    public static func build(_ boxes: [MailMailbox]) -> [MailboxTree] {
        var roots: [MailboxTree] = []
        for box in boxes.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let parts = box.encodedPathComponents
            insert(box, parts: parts, prefix: "", into: &roots)
        }
        return ordered(roots)
    }

    private static func ordered(_ nodes: [MailboxTree]) -> [MailboxTree] {
        let roles: [MailMailbox.Role] = [.inbox, .drafts, .sent, .archive, .other, .junk, .trash]
        return nodes.map { node in
            var node = node
            node.children = ordered(node.children)
            return node
        }.sorted { left, right in
            let leftRole = roles.firstIndex(of: left.mailbox?.role ?? .other) ?? roles.count
            let rightRole = roles.firstIndex(of: right.mailbox?.role ?? .other) ?? roles.count
            return leftRole != rightRole ? leftRole < rightRole : left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    private static func insert(_ box: MailMailbox, parts: [String], prefix: String, into nodes: inout [MailboxTree]) {
        guard let title = parts.first else { return }
        let path = prefix.isEmpty ? title : prefix + "/" + title
        let index: Int
        if let existing = nodes.firstIndex(where: { $0.accountID == box.accountID && $0.path == path }) { index = existing }
        else {
            index = nodes.count
            nodes.append(.init(accountID: box.accountID, path: path, title: title.removingPercentEncoding ?? title, mailbox: nil, children: []))
        }
        if parts.count == 1 { nodes[index].mailbox = box }
        else { insert(box, parts: Array(parts.dropFirst()), prefix: path, into: &nodes[index].children) }
    }
}
