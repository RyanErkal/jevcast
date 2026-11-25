import SwiftUI
import LauncherCore

/// Widths of the mail columns in the panel. The reader or composer takes the rest, so the panel
/// fits from its smallest view width (860) to its largest (1320). See `MailColumnLayout`.
enum MailPanelLayout {
    static func sidebarWidth(_ total: CGFloat) -> CGFloat { CGFloat(MailColumnLayout.defaultSidebar(total: Double(total))) }
    static func listWidth(_ total: CGFloat, sidebar: CGFloat, split: MailReading.Split) -> CGFloat {
        CGFloat(MailColumnLayout.defaultList(total: Double(total), sidebar: Double(sidebar), fraction: Double(split.listFraction)))
    }
    /// The columns for this page: widths you dragged to, else the ones that follow the panel.
    /// A list width dragged under one `Split` replaces that Split's width until reset.
    @MainActor static func columns(_ total: CGFloat, page: MailPage, split: MailReading.Split) -> MailColumnLayout {
        MailColumnLayout.resolve(total: Double(total), showsSidebar: page.showsSidebar, listFraction: Double(split.listFraction),
                                 customSidebar: page.sidebarWidth.map(Double.init), customList: page.customListWidth(for: split).map(Double.init))
    }
}

/// Mail in the panel: the mailbox sidebar, the list, and the message or the open draft beside it.
/// The composer keeps the sidebar and list on screen, so picking a mailbox never closes a draft.
/// Outbox shows in place of the list. An expanded message fills the panel. The message or draft
/// keeps one place in the layout, so a column that comes or goes never loads the message again;
/// columns slide in and out with `MailStyle.motion`.
struct MailWorkspace: View {
    @ObservedObject var page: MailPage
    @ObservedObject var mail: MailModel
    @AppStorage(MailReading.splitKey) private var splitRaw = MailReading.Split.balanced.rawValue
    private var split: MailReading.Split { MailReading.Split(rawValue: splitRaw) ?? .balanced }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let columns = MailPanelLayout.columns(total, page: page, split: split)
            HStack(spacing: 0) {
                if let tool = page.tool, let features = page.features {
                    MailToolsView(tool: tool, page: page, center: features)
                } else {
                    if !reading && page.showsSidebar {
                        sidebar.frame(width: CGFloat(columns.sidebar))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        MailColumnDivider(width: CGFloat(columns.sidebar), title: "mailboxes") {
                            page.dragSidebar(to: CGFloat(MailColumnLayout.clampSidebar(Double($0), total: Double(total))))
                        } end: { page.keepColumnWidths() } reset: { page.resetSidebarWidth() }
                    }
                    if !reading {
                        MailPanelList(page: page, mail: mail)
                            .frame(width: outboxFills ? nil : CGFloat(columns.list))
                            .frame(maxWidth: outboxFills ? .infinity : nil)
                            .transition(.opacity)
                        if !outboxFills {
                            MailColumnDivider(width: CGFloat(columns.list), title: "message list") {
                                page.dragList(to: CGFloat(MailColumnLayout.clampList(Double($0), total: Double(total), sidebar: columns.sidebar)), split: split)
                            } end: { page.keepColumnWidths() } reset: { page.resetListWidth(for: split) }
                        }
                    }
                    if !outboxFills { detail }
                }
            }
            .animation(MailStyle.motion, value: page.expanded)
            .animation(MailStyle.motion, value: page.showsSidebar)
            .animation(MailStyle.motion, value: page.composing)
        }
    }

    /// The selected message alone, after Space, Return, or a double click. A draft keeps the columns.
    private var reading: Bool { page.accountDetailsID == nil && page.expanded && !page.composing && mail.selected != nil }
    /// Outbox has no message to read, so it takes the list's and the reader's room unless a draft is open.
    private var outboxFills: Bool { !reading && page.accountDetailsID == nil && mail.place == .outbox && !page.composing }

    /// The mailboxes, with Mail Settings and how current the mail is at the bottom.
    private var sidebar: some View {
        VStack(spacing: 0) {
            MailSidebar(model: mail, center: page.accountCenter) { page.accountDetailsID = $0 }
            MailSidebarFooter(page: page, mail: mail, center: page.accountCenter)
        }
    }

    private var detail: some View {
        Group {
            if let id = page.accountDetailsID {
                MailAccountConnectionView(center: page.accountCenter, recovery: page.accountCenter.recovery, accountID: id) {
                    page.accountDetailsID = nil
                }.id(id)
            } else if page.composing {
                ComposeView(model: mail, schedules: page.features?.schedules, preferences: page.composerPreferences).id(mail.draft?.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            else {
                MailReader(model: mail, expanded: $page.expanded, features: page.features)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The list column: the mailbox's name and tools, the one-click filters (or, while the filter
/// field has text, where the search looks), the messages, and the bar for several selected rows.
/// Outbox shows its send history here instead. Each header line keeps its height, so the list
/// never moves when a search starts or a filter turns on.
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
                MailMessageList(model: mail, page: page, scrollsToSelection: true, pick: { page.pick($0) }) { page.read($0) }
                    .scrollContentBackground(.hidden)
                MailBulkBar(model: mail, page: page)
            }
        }
    }

    private var searching: Bool { !mail.search.isEmpty && mail.place != .outbox }
    /// Mail Settings has no gear while the sidebar is hidden, so the list's menu offers it.
    private var settingsHere: Bool { page.features != nil && !page.showsSidebar }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { withAnimation(MailStyle.motion) { page.showsSidebar.toggle() } } label: { Image(systemName: "sidebar.left") }
                    .help(page.showsSidebar ? "Hide mailboxes" : "Show mailboxes")
                // While searching, the title says what was found; without the sidebar, it picks the mailbox.
                if searching {
                    Text(MailSearchSummary.title(count: mail.conversationGroups.count, more: mail.hasMore, loading: mail.isLoading))
                        .font(.headline).lineLimit(1).help(searchSummary)
                } else if page.showsSidebar { Text(mail.placeTitle).font(.headline).lineLimit(1) }
                else { MailPlacePicker(model: mail).font(.headline) }
                MailEmptyButton(model: mail)
                Spacer(minLength: 4)
                if mail.place != .outbox { MailFilterButton(model: mail).labelStyle(.iconOnly) }
                // List actions only. Mail Settings is at the bottom of the sidebar, and here while it is hidden.
                if mail.place != .outbox || settingsHere {
                    Menu {
                        if mail.place == .inbox { Text("\(mail.unreadInInbox) unread") }
                        if mail.place != .outbox { MailListTools(model: mail) }
                        if settingsHere {
                            Divider()
                            Menu("Mail Settings") { MailSettingsMenuItems(page: page) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden).fixedSize().help("List actions")
                }
                // With the sidebar showing, its status line says that Mail is checking; without it, a note does.
                Button { mail.checkMail(announce: !page.showsSidebar) } label: { Image(systemName: "arrow.clockwise") }.help("Check for new mail")
                Button { mail.compose() } label: { Image(systemName: "square.and.pencil") }.help("New message (⌘N)")
            }
            .buttonStyle(MailIconButtonStyle())
            MailClosedNote(model: mail)
            if mail.place != .outbox {
                // The same height either way: the search's scope takes the filters' place.
                Group {
                    if searching {
                        // The launcher's field is the search; this picks where it looks.
                        Picker("Search in", selection: $mail.searchScope) {
                            ForEach(MailModel.SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    } else {
                        MailFilterChips(model: mail)
                    }
                }
                .frame(height: MailFilterChips.height)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// The whole sentence, in the title's tooltip: what was found, for what, and where.
    private var searchSummary: String {
        let count = mail.conversationGroups.count
        let found = MailSearchSummary.title(count: count, more: mail.hasMore, loading: mail.isLoading)
        let scope = mail.searchScope == .mailbox ? mail.placeTitle : "all accounts"
        return found + " for “" + mail.search + "” in " + scope
    }
}

/// The list's title while searching: "3 results", "12+ results", "Searching…", or "No results".
enum MailSearchSummary {
    static func title(count: Int, more: Bool, loading: Bool) -> String {
        if count == 0 { return loading ? "Searching…" : "No results" }
        return "\(count)\(more ? "+" : "") result\(count == 1 && !more ? "" : "s")"
    }
}
