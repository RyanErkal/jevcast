import SwiftUI
import LauncherCore

/// Widths of the mail columns in the panel. The reader or composer takes the rest, so the panel
/// fits from its smallest view width (860) to its largest (1320).
enum MailPanelLayout {
    static func sidebarWidth(_ total: CGFloat) -> CGFloat { min(220, max(190, (total * 0.17).rounded())) }
    static func listWidth(_ total: CGFloat, sidebar: CGFloat, split: MailReading.Split) -> CGFloat {
        min(380, max(240, ((total - sidebar) * split.listFraction).rounded()))
    }
}

/// Mail in the panel: the mailbox sidebar, the list, and the message or the open draft beside it.
/// The composer keeps the sidebar and list on screen, so picking a mailbox never closes a draft.
/// Outbox shows in place of the list. An expanded message fills the panel.
struct MailWorkspace: View {
    @ObservedObject var page: MailPage
    @ObservedObject var mail: MailModel
    @AppStorage(MailReading.splitKey) private var splitRaw = MailReading.Split.balanced.rawValue
    private var split: MailReading.Split { MailReading.Split(rawValue: splitRaw) ?? .balanced }

    var body: some View {
        GeometryReader { geo in
            let sidebar = MailPanelLayout.sidebarWidth(geo.size.width)
            HStack(spacing: 0) {
                if reading {
                    detail
                } else {
                    if page.showsSidebar {
                        MailSidebar(model: mail).frame(width: sidebar)
                        Divider()
                    }
                    if outboxFills {
                        MailPanelList(page: page, mail: mail).frame(maxWidth: .infinity)
                    } else {
                        MailPanelList(page: page, mail: mail)
                            .frame(width: MailPanelLayout.listWidth(geo.size.width, sidebar: page.showsSidebar ? sidebar : 0, split: split))
                        Divider()
                        detail
                    }
                }
            }
        }
    }

    /// The selected message alone, after Space, Return, or a double click. A draft keeps the columns.
    private var reading: Bool { page.expanded && !page.composing && mail.selected != nil }
    /// Outbox has no message to read, so it takes the list's and the reader's room unless a draft is open.
    private var outboxFills: Bool { mail.place == .outbox && !page.composing }

    private var detail: some View {
        Group {
            if page.composing { ComposeView(model: mail).id(mail.draft?.id) }
            else { MailReader(model: mail, expanded: $page.expanded) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The list column: the mailbox's name and tools, the search scope while the filter has text,
/// and the messages. Outbox shows its send history here instead.
struct MailPanelList: View {
    @ObservedObject var page: MailPage
    @ObservedObject var mail: MailModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if mail.place == .outbox {
                MailDeliveryView(model: mail)
            } else {
                if mail.place == .drafts { MailSavedDraftList(model: mail) }
                // A double click reads the message across the panel.
                MailMessageList(model: mail, scrollsToSelection: true, pick: { page.pick($0) }) { page.read($0) }
                    .scrollContentBackground(.hidden)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { page.showsSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(page.showsSidebar ? "Hide mailboxes" : "Show mailboxes")
                // Without the sidebar, the title picks the mailbox.
                if page.showsSidebar { Text(mail.placeTitle).font(.headline).lineLimit(1) }
                else { MailPlacePicker(model: mail).font(.headline) }
                if mail.place == .inbox, mail.unreadInInbox > 0 {
                    Text("\(mail.unreadInInbox) unread").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                MailEmptyButton(model: mail)
                Spacer(minLength: 4)
                Button { mail.checkMail() } label: { Image(systemName: "arrow.clockwise") }.help("Check for new mail")
                Button { mail.compose() } label: { Image(systemName: "square.and.pencil") }.help("New message (⌘N)")
            }
            .buttonStyle(.borderless)
            MailClosedNote(model: mail)
            // The launcher's field is the search; this picks where it looks.
            if !mail.search.isEmpty, mail.place != .outbox {
                Picker("Search in", selection: $mail.searchScope) {
                    ForEach(MailModel.SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
