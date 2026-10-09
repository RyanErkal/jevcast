import SwiftUI
import LauncherCore

/// The message list in the panel. Rows keep their message IDs, and the next page loads when a
/// row near the end appears.
struct MailMessageList: View {
    @ObservedObject var model: MailModel
    /// The panel scrolls to a message the keyboard selects.
    var scrollsToSelection = false
    /// A row the user clicked. The panel picks it through its page, so an open draft is kept.
    var pick: ((Int64) -> Void)?
    var onDoubleClick: ((Int64) -> Void)?

    var body: some View {
        let groups = model.conversationGroups
        let activeRow = groups.first { $0.messages.contains { $0.summary.rowID == model.selectedID } }?.latest.summary.rowID
        return ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(groups) { conversation in
                    MailConversationSummaryRow(conversation: conversation,
                        isVIP: conversation.messages.contains { model.isVIP($0.summary) },
                        delete: { model.delete(conversation.latest.summary.rowID) })
                        .tag(conversation.latest.summary.rowID).id(conversation.latest.summary.rowID)
                        .listRowBackground(activeRow == conversation.latest.summary.rowID
                            ? Color.accentColor.opacity(0.22) : Color.clear)
                        .onDrag { NSItemProvider(object: NSString(string: String(conversation.latest.summary.rowID))) }
                        .onAppear {
                            if conversation.messages.contains(where: { $0.summary.rowID == model.pageTriggerID }) { model.loadNextPage() }
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.delete(conversation.latest.summary.rowID) }
                            Button("Delete All from " + conversation.latest.summary.sender, role: .destructive) {
                                model.select(conversation.latest.summary.rowID, byUser: false)
                                model.deleteAllFromSender()
                            }
                        }
                }
                if model.hasMore {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        .task(id: model.bottom) { model.loadNextPage() }
                        .selectionDisabled()
                } else if model.olderOnServer, !model.messages.isEmpty {
                    // The end of what this Mac has: a Jevcast account reads the next older batch.
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        .task(id: model.bottom) { await model.loadOlder() }
                        .selectionDisabled()
                }
                if model.olderOnServer, model.messages.isEmpty, !model.canSearchServer {
                    Button("Load older mail") { Task { await model.loadOlder() } }
                        .buttonStyle(.link).selectionDisabled()
                }
                if model.canSearchServer || model.serverSearch != .available { MailServerSearchFooter(model: model).selectionDisabled() }
                switch model.bodySearch {
                case .more:
                    Button("Search more message text") { model.searchBodies() }
                        .buttonStyle(.link).frame(maxWidth: .infinity).selectionDisabled()
                case .running where !model.hasMore:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).selectionDisabled()
                default:
                    EmptyView()
                }
            }
            .contextMenu(forSelectionType: Int64.self, menu: { _ in }) { ids in
                guard let id = ids.first, let onDoubleClick else { return }
                onDoubleClick(id)
            }
            .listStyle(.inset)
            .overlay {
                if model.messages.isEmpty && model.bodySearch != .more && !model.olderOnServer && !model.canSearchServer {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: model.selectedConversationRowID) { _, id in if scrollsToSelection, let id { proxy.scrollTo(id) } }
            // The list comes back after a reply in the panel, scrolled to the message it left.
            .onAppear {
                guard scrollsToSelection, let id = model.selectedConversationRowID else { return }
                DispatchQueue.main.async { proxy.scrollTo(id) }
            }
        }
    }

    private var selection: Binding<Set<Int64>> {
        Binding(get: { model.selectedConversationRowIDs }, set: { ids in
            model.selectConversationRows(ids)
            // A single click also gives the page draft/reader handling. Multi-selection stays
            // in the list so the page's one-message selection cannot collapse the set.
            if ids.count <= 1, let id = ids.sorted().last, let pick { pick(id) }
        })
    }

    private var emptyText: String {
        if !model.search.isEmpty { return model.bodySearch == .running ? "Searching…" : "No matches" }
        if model.place == .drafts, !model.savedDrafts.isEmpty { return "No other drafts" }
        return "\(model.placeTitle) is empty"
    }
}

private struct MailServerSearchFooter: View {
    @ObservedObject var model: MailModel
    var body: some View {
        VStack(spacing: 6) {
            switch model.serverSearch {
            case .available:
                Text("Showing mail downloaded to this Mac.").foregroundStyle(.secondary)
                Button(model.search.isEmpty ? "Find \(model.placeTitle.lowercased()) on server" : "Search server mail") { model.searchServer() }
                    .buttonStyle(.link)
            case .running: ProgressView("Searching server…").controlSize(.small)
            case .more:
                Button("Search more server mail") { model.searchServer() }.buttonStyle(.link)
            case .complete:
                Text("Server search complete").foregroundStyle(.secondary)
                Button("Search again") { model.resetServerSearch(); model.searchServer() }.buttonStyle(.link)
            case .limited(let reason): Text(reason).foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).foregroundStyle(.orange)
                Button("Retry server search") { model.searchServer() }.buttonStyle(.link)
            }
        }.font(.caption).frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

/// Picks the list: Inbox (the default), All Mail, Unread, Flagged, or one mailbox of an account.
/// Each account has its own section, with Inbox, Drafts, Sent, Junk, Trash, and Archive first,
/// and each mailbox shows its unread count, or for Junk and Trash how many messages it holds.
struct MailPlacePicker: View {
    @ObservedObject var model: MailModel
    var body: some View {
        Menu {
            Button("Inbox") { model.place = .inbox }
            Button("All Mail") { model.place = .allMail }
            Button("Unread") { model.place = .unread }
            Button("Flagged") { model.place = .flagged }
            Button("Drafts") { model.place = .drafts }
            Button("Sent") { model.place = .sent }
            Button("Outbox") { model.place = .outbox }
            ForEach(model.accounts, id: \.self) { account in
                Divider()
                Section(model.accountTitle(account)) {
                    ForEach(Self.ordered(model.mailboxes.filter { $0.accountID == account })) { box in
                        Button(Self.label(box)) { model.place = .mailbox(box.rowID) }
                    }
                }
            }
        } label: {
            Text(model.placeTitle)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Choose a mailbox")
    }

    private static let roleOrder: [MailMailbox.Role] = [.inbox, .drafts, .sent, .junk, .trash, .archive, .other]

    static func ordered(_ boxes: [MailMailbox]) -> [MailMailbox] {
        boxes.sorted { a, b in
            let left = roleOrder.firstIndex(of: a.role) ?? roleOrder.count, right = roleOrder.firstIndex(of: b.role) ?? roleOrder.count
            return left != right ? left < right : a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    /// "Inbox (12 unread)", "Bin (8)", or "Clients/Acme". Counts come from the server when it gave them.
    static func label(_ box: MailMailbox) -> String {
        let name = box.role == .inbox ? "Inbox" : box.path.hasPrefix("[Gmail]/") ? String(box.path.dropFirst("[Gmail]/".count)) : box.path
        if box.role == .trash || box.role == .junk {
            let total = box.serverTotal ?? box.total
            return total > 0 ? "\(name) (\(total))" : name
        }
        let unread = box.serverUnread ?? box.unread
        return unread > 0 ? "\(name) (\(unread) unread)" : name
    }
}

/// Empty Trash or Empty Junk, beside the picker while one of them is on screen. It counts what is
/// on the server first and asks; only the messages counted are removed, for good.
struct MailEmptyButton: View {
    @ObservedObject var model: MailModel
    var body: some View {
        if let box = model.emptiableMailbox {
            Button(model.preparingEmpty ? "Counting…" : "Empty \(MailPlacePicker.label(box).split(separator: " (").first.map(String.init) ?? box.name)") {
                model.prepareEmpty()
            }
            .buttonStyle(.borderless).font(.caption).disabled(model.preparingEmpty)
            .help("Deletes every message in \(box.name) permanently. You see the count and confirm first.")
            .alert(Text(alertTitle), isPresented: Binding(get: { model.emptyRequest != nil }, set: { if !$0 { model.emptyRequest = nil } })) {
                Button("Cancel", role: .cancel) { model.emptyRequest = nil }
                Button("Delete Permanently", role: .destructive) { model.confirmEmpty() }
            } message: {
                Text("They are removed from the server for good. This cannot be undone. Mail that arrives after this count stays.")
            }
        }
    }

    private var alertTitle: String {
        guard let request = model.emptyRequest else { return "" }
        return "Delete \(request.uids.count) message\(request.uids.count == 1 ? "" : "s") in \(request.mailbox.name) permanently?"
    }
}

/// A small note while Apple Mail is closed: its index only gets new mail while it runs.
struct MailClosedNote: View {
    @ObservedObject var model: MailModel
    var body: some View {
        if !model.mailRunning {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                Text("Apple Mail is closed, so new mail is not arriving.").foregroundStyle(.secondary)
                Button("Open Mail") { model.openMailInBackground() }.buttonStyle(.link)
            }
            .font(.caption)
        }
    }
}
