import SwiftUI
import LauncherCore

/// Unified views, favourites, and account folders, all inside the launcher panel.
struct MailSidebar: View {
    @ObservedObject var model: MailModel
    @ObservedObject var center: NativeMailCenter
    let showAccount: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 0) {
                        MailSidebarHeading(title: "Mailboxes")
                        row("Inbox", "tray", .inbox, count: model.unreadInInbox)
                        row("All Mail", "tray.full", .allMail)
                        row("Unread", "envelope.badge", .unread)
                        row("Flagged", "flag", .flagged)
                        row("Drafts", "doc", .drafts, count: model.savedDrafts.count)
                        row("Sent", "paperplane", .sent)
                        row("Outbox", "tray.and.arrow.up", .outbox, count: model.pendingDeliveryCount)
                    }
                    if !model.favoriteMailboxes.isEmpty {
                        VStack(spacing: 0) {
                            MailSidebarHeading(title: "Favourites")
                            ForEach(model.favoriteMailboxes) { box in
                                MailSidebarMailbox(box: box, title: box.name, model: model)
                            }
                        }
                    }
                    ForEach(accountIDs, id: \.self) { account in
                        accountSection(account)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 12)
            }
            if model.persistenceProblem != nil {
                Label("Drafts need attention", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(12)
            }
        }
    }

    private var accountLabels: [String: String] {
        MailSidebarAccounts.labels(accountIDs.map { (id: $0, address: accountTitle($0)) })
    }

    private var accountIDs: [String] {
        MailSidebarAccounts.ids(mailboxAccounts: model.accounts, configured: center.backend == .jevcast ? center.accounts : [])
            .sorted { accountTitle($0).localizedStandardCompare(accountTitle($1)) == .orderedAscending }
    }

    private func accountTitle(_ id: String) -> String {
        center.accounts.first { $0.id == id }?.email ?? model.accountTitle(id)
    }

    private func accountSection(_ account: String) -> some View {
        let isExpanded = expanded("account:" + account)
        let folders = MailSidebarFolders(model.mailboxes.filter { $0.accountID == account })
        let state: MailAccountSync.State? = center.backend == .jevcast ? center.states[account] : nil
        return VStack(alignment: .leading, spacing: 0) {
            accountHeader(account, state: state, isExpanded: isExpanded)
            if center.backend == .jevcast, center.accounts.contains(where: { $0.id == account }) {
                accountConnection(account, state: state)
            }
            if isExpanded.wrappedValue { accountFolders(folders) }
        }
    }

    private func accountHeader(_ account: String, state: MailAccountSync.State?, isExpanded: Binding<Bool>) -> some View {
        let label = accountLabels[account] ?? account
        let title = accountTitle(account)
        let stateLabel = status(state)
        let accessibilityLabel = label + ", " + title
        let accessibilityValue = stateLabel + ", " + (isExpanded.wrappedValue ? "Expanded" : "Collapsed")
        return Button { isExpanded.wrappedValue.toggle() } label: {
            accountHeaderLabel(label, state: state, isExpanded: isExpanded.wrappedValue)
        }
        .buttonStyle(.plain)
        .help(title + " · " + stateLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private func accountHeaderLabel(_ label: String, state: MailAccountSync.State?, isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor(state)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary).padding(.horizontal, 8)
        .frame(height: 24).contentShape(Rectangle())
    }

    private func accountConnection(_ account: String, state: MailAccountSync.State?) -> some View {
        Button { showAccount(account) } label: {
            HStack(spacing: 4) {
                Text(status(state))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).font(.system(size: 11))
        .foregroundStyle(statusColor(state))
        .padding(.horizontal, 8).padding(.bottom, 4)
        .help("View connection details for " + accountTitle(account))
    }

    @ViewBuilder private func accountFolders(_ folders: MailSidebarFolders) -> some View {
        ForEach(folders.primary) { node in
            MailFolderNode(node: node, title: folders.title(node), model: model)
        }
        ForEach(folders.providerFolders) { node in
            MailProviderFolders(node: node, model: model)
        }
        ForEach(folders.folders) { node in
            MailFolderNode(node: node, title: node.title, model: model)
        }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !model.collapsedMailboxKeys.contains(id) }, set: { model.setMailboxExpanded(id, $0) })
    }

    private func row(_ title: String, _ symbol: String, _ place: MailModel.Place, count: Int = 0) -> some View {
        MailSidebarRow(title: title, symbol: symbol, count: count, selected: model.place == place) { model.place = place }
    }

    private func statusColor(_ state: MailAccountSync.State?) -> Color {
        switch state {
        case .ready: return .green
        case .syncing: return .accentColor
        case .failed: return .orange
        default: return .secondary
        }
    }

    private func status(_ state: MailAccountSync.State?) -> String {
        MailAccountConnectionStatus(state: state).title
    }
}

private struct MailFolderNode: View {
    let node: MailboxTree
    let title: String
    @ObservedObject var model: MailModel

    private var expanded: Binding<Bool> {
        Binding(get: { !model.collapsedMailboxKeys.contains(node.id) }, set: { model.setMailboxExpanded(node.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let box = node.mailbox {
                MailSidebarMailbox(box: box, title: title, model: model, expanded: node.children.isEmpty ? nil : expanded)
            } else if !node.children.isEmpty {
                MailSidebarRow(title: title, symbol: "folder", expanded: expanded) { expanded.wrappedValue.toggle() }
            }
            if !node.children.isEmpty && expanded.wrappedValue {
                VStack(spacing: 0) {
                    ForEach(node.children) { child in MailFolderNode(node: child, title: child.title, model: model) }
                }.padding(.leading, 12)
            }
        }
    }
}

private struct MailProviderFolders: View {
    let node: MailboxTree
    @ObservedObject var model: MailModel

    private var expanded: Binding<Bool> {
        Binding(get: { model.expandedSidebarGroupKeys.contains(node.id) }, set: { model.setSidebarGroupExpanded(node.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let box = node.mailbox {
                MailSidebarMailbox(box: box, title: node.title, model: model, expanded: node.children.isEmpty ? nil : expanded)
            } else {
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("Gmail folders")
                        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 31).padding(.trailing, 8).frame(height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            }
            if expanded.wrappedValue {
                ForEach(node.children) { child in MailFolderNode(node: child, title: child.title, model: model) }
            }
        }
    }
}
