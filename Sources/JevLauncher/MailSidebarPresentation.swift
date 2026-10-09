import Foundation
import LauncherCore

/// Reorders the sidebar only. Real mailbox identities and their children stay intact.
struct MailSidebarFolders {
    let primary: [MailboxTree]
    let folders: [MailboxTree]
    let providerFolders: [MailboxTree]
    private static let primaryRoles: [MailMailbox.Role] = [.inbox, .drafts, .sent, .archive, .trash]

    init(_ mailboxes: [MailMailbox]) {
        var promoted: [MailboxTree] = []
        func remaining(_ nodes: [MailboxTree]) -> [MailboxTree] {
            nodes.compactMap { original in
                if let box = original.mailbox, Self.primaryRoles.contains(box.role) {
                    promoted.append(original)
                    return nil
                }
                var node = original
                node.children = remaining(node.children)
                return node.mailbox == nil && node.children.isEmpty ? nil : node
            }
        }
        let roots = remaining(MailboxTree.build(mailboxes))
        primary = promoted.sorted {
            let left = Self.primaryRoles.firstIndex(of: $0.mailbox!.role)!
            let right = Self.primaryRoles.firstIndex(of: $1.mailbox!.role)!
            return left == right ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : left < right
        }
        providerFolders = roots.filter(Self.isProviderRoot)
        folders = roots.filter { !Self.isProviderRoot($0) }
    }

    func title(_ node: MailboxTree) -> String {
        guard let box = node.mailbox else { return node.title }
        if primary.filter({ $0.mailbox?.role == box.role }).count > 1 { return box.path }
        switch box.role {
        case .inbox: return "Inbox"
        case .drafts: return "Drafts"
        case .sent: return "Sent"
        case .archive: return box.name.caseInsensitiveCompare("All Mail") == .orderedSame ? "All Mail" : "Archive"
        case .trash: return "Trash"
        default: return node.title
        }
    }

    private static func isProviderRoot(_ node: MailboxTree) -> Bool {
        ["[gmail]", "[google mail]"].contains(node.title.lowercased())
    }
}

enum MailSidebarAccounts {
    /// An account with no downloaded folders still needs a visible recovery action.
    static func ids(mailboxAccounts: [String], configured: [NativeMailAccount]) -> [String] {
        Array(Set(mailboxAccounts).union(configured.map(\.id)))
    }
    /// Short labels come from addresses, never the sender's display name.
    static func labels(_ accounts: [(id: String, address: String)]) -> [String: String] {
        var labels: [String: String] = [:]
        for account in accounts { labels[account.id] = shortLabel(account.id, account.address) }
        let collisions = Dictionary(grouping: accounts, by: { labels[$0.id]!.lowercased() })
        for group in collisions.values where group.count > 1 {
            for account in group { labels[account.id] = account.address.contains("@") ? account.address : account.id }
        }
        let duplicates = Dictionary(grouping: accounts, by: { labels[$0.id]!.lowercased() })
        for group in duplicates.values where group.count > 1 {
            for (index, account) in group.sorted(by: { $0.id < $1.id }).enumerated() {
                labels[account.id] = labels[account.id]! + " (\(index + 1))"
            }
        }
        return labels
    }

    private static func shortLabel(_ id: String, _ address: String) -> String {
        if id.isEmpty { return "On My Mac" }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return UUID(uuidString: id) == nil ? id : "Account " + id.suffix(4)
        }
        let domain = parts[1].lowercased()
        let consumer = ["gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com", "yahoo.co.uk", "aol.com", "proton.me", "protonmail.com"]
        let value = consumer.contains(domain) ? String(parts[0]) : String(parts[1].split(separator: ".").first ?? parts[1])
        return value.prefix(1).uppercased() + value.dropFirst()
    }
}
