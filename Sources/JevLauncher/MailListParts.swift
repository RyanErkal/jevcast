import SwiftUI
import LauncherCore

/// The message list for the mail window and the panel. Rows keep their message IDs, and the
/// next page loads when a row near the end appears.
struct MailMessageList: View {
    @ObservedObject var model: MailModel
    /// The panel scrolls to a message the keyboard selects.
    var scrollsToSelection = false
    var onDoubleClick: ((Int64) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selectedID) {
                ForEach(model.messages) { message in
                    MailRow(message: message, delete: { model.delete(message.rowID) },
                            deleteAll: { model.select(message.rowID, byUser: false); model.deleteAllFromSender() })
                        .equatable()
                        .tag(message.rowID).id(message.rowID)
                        .onAppear { if message.rowID == model.pageTriggerID { model.loadNextPage() } }
                }
                if model.hasMore {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        .task(id: model.bottom) { model.loadNextPage() }
                        .selectionDisabled()
                }
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
                if model.messages.isEmpty && model.bodySearch != .more {
                    Text(model.search.isEmpty ? "\(model.placeTitle) is empty" : model.bodySearch == .running ? "Searching…" : "No matches")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: model.selectedID) { _, id in if scrollsToSelection, let id { proxy.scrollTo(id) } }
        }
    }
}

/// Picks the list: Inbox (the default), All Mail, Unread, Flagged, or one mailbox by account.
struct MailPlacePicker: View {
    @ObservedObject var model: MailModel
    var body: some View {
        Menu {
            Button("Inbox") { model.place = .inbox }
            Button("All Mail") { model.place = .allMail }
            Button("Unread") { model.place = .unread }
            Button("Flagged") { model.place = .flagged }
            ForEach(model.accounts, id: \.self) { account in
                Divider()
                ForEach(model.mailboxes.filter { $0.accountID == account }.sorted { $0.path < $1.path }) { box in
                    Button(box.path) { model.place = .mailbox(box.rowID) }
                }
            }
        } label: {
            Text(model.placeTitle)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Choose a mailbox")
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
