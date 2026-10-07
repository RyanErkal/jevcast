import SwiftUI
import LauncherCore

/// The mailboxes beside the list in the panel: unified views, favourites, then each account's
/// folders, which expand and collapse. Outbox opens in place of the list.
struct MailSidebar: View {
    @ObservedObject var model: MailModel
    @ObservedObject private var center = NativeMailCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Mailboxes") {
                    row("Inbox", "tray", .inbox, count: model.unreadInInbox)
                    row("All Mail", "tray.full", .allMail)
                    row("Unread", "envelope.badge", .unread)
                    row("Flagged", "flag", .flagged)
                    row("Drafts", "doc", .drafts, count: model.savedDrafts.count)
                    row("Sent", "paperplane", .sent)
                    row("Outbox", "tray.and.arrow.up", .outbox, count: model.pendingDeliveryCount)
                }
                if !model.favoriteMailboxes.isEmpty {
                    Section("Favourites") {
                        ForEach(model.favoriteMailboxes) { box in mailbox(box, title: box.name) }
                    }
                }
                ForEach(model.accounts, id: \.self) { account in
                    Section {
                        DisclosureGroup(isExpanded: expanded("account:" + account)) {
                            ForEach(MailboxTree.build(model.mailboxes.filter { $0.accountID == account })) { node in
                                MailFolderNode(node: node, model: model)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.accountTitle(account)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                if let state = center.states[account] { Text(status(state)).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            if model.persistenceProblem != nil {
                Label("Drafts need attention", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(12)
            }
        }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !model.collapsedMailboxKeys.contains(id) }, set: { model.setMailboxExpanded(id, $0) })
    }

    private func row(_ title: String, _ symbol: String, _ place: MailModel.Place, count: Int = 0) -> some View {
        MailSidebarRow(title: title, symbol: symbol, count: count, selected: model.place == place) { model.place = place }
    }

    private func mailbox(_ box: MailMailbox, title: String) -> some View {
        MailSidebarMailbox(box: box, title: title, model: model)
    }

    private func status(_ state: MailAccountSync.State) -> String {
        switch state {
        case .starting: return "Starting"
        case .syncing: return "Syncing…"
        case .ready: return "Up to date"
        case .failed(_, let signIn): return signIn ? "Sign in required" : "Sync needs attention"
        }
    }
}

private struct MailFolderNode: View {
    let node: MailboxTree
    @ObservedObject var model: MailModel

    var body: some View {
        if node.children.isEmpty {
            if let box = node.mailbox { MailSidebarMailbox(box: box, title: node.title, model: model) }
        } else {
            DisclosureGroup(isExpanded: Binding(get: { !model.collapsedMailboxKeys.contains(node.id) }, set: { model.setMailboxExpanded(node.id, $0) })) {
                ForEach(node.children) { child in MailFolderNode(node: child, model: model) }
            } label: {
                if let box = node.mailbox { MailSidebarMailbox(box: box, title: node.title, model: model) }
                else { Label(node.title, systemImage: "folder").font(.system(size: 12)).lineLimit(1) }
            }
        }
    }
}

private struct MailSidebarMailbox: View {
    let box: MailMailbox
    let title: String
    @ObservedObject var model: MailModel

    var body: some View {
        MailSidebarRow(title: title, symbol: symbol, count: count, selected: model.place == .mailbox(box.rowID),
                       partial: box.initialized == false) { model.place = .mailbox(box.rowID) }
            .help(box.initialized == false ? "Opens and downloads this folder" : box.syncComplete == false ? "Older messages load as you scroll" : box.path)
            .contextMenu {
                Button(model.isFavorite(box) ? "Remove from Favourites" : "Add to Favourites") { model.toggleFavorite(box) }
            }
    }
    private var count: Int {
        [.junk, .trash, .drafts].contains(box.role) ? box.serverTotal ?? box.total : box.serverUnread ?? box.unread
    }
    private var symbol: String {
        switch box.role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "exclamationmark.shield"
        case .archive: return "archivebox"
        case .other: return "folder"
        }
    }
}

private struct MailSidebarRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    var partial = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if partial { Image(systemName: "icloud.and.arrow.down").font(.caption2).foregroundStyle(.tertiary) }
                if count > 0 { Text(count.formatted()).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.system(size: 12)).padding(.vertical, 5).padding(.horizontal, 6)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
