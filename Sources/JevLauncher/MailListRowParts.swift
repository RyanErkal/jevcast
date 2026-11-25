import AppKit
import SwiftUI
import LauncherCore

extension MailRowAction {
    /// The name in a menu or a tooltip. `unread`, `flagged`, and `junk` describe the rows it acts on.
    func title(unread: Bool = false, flagged: Bool = false, junk: Bool = false, sender: String = "") -> String {
        switch self {
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .editDraft: return "Edit Draft"
        case .archive: return "Archive"
        case .readToggle: return unread ? "Mark as Read" : "Mark as Unread"
        case .flagToggle: return flagged ? "Unflag" : "Flag"
        case .snooze: return "Snooze…"
        case .move: return "Move To"
        case .junkToggle: return junk ? "Not Junk" : "Mark as Junk"
        case .delete: return "Delete"
        case .deleteAllFromSender: return "Delete All from " + (sender.isEmpty ? "Sender" : sender)
        }
    }

    /// The name of a button under the pointer, which acts on its own row.
    func hoverTitle(unread: Bool) -> String { title(unread: unread) }

    /// The tooltip: the name and the key that does the same to the message on screen.
    func help(unread: Bool = false, flagged: Bool = false) -> String {
        let name = title(unread: unread, flagged: flagged)
        return key.map { name + " (" + $0 + ")" } ?? name
    }

    var symbol: String {
        switch self {
        case .archive: return "archivebox"
        case .delete: return "trash"
        case .flagToggle: return "flag"
        case .move: return "folder"
        case .snooze: return "clock"
        default: return "envelope"
        }
    }

    /// The key shown beside the item in the right-click menu. The page handles the key itself.
    var shortcut: KeyboardShortcut? {
        switch self {
        case .reply: return KeyboardShortcut("r")
        case .replyAll: return KeyboardShortcut("r", modifiers: [.command, .shift])
        case .forward: return KeyboardShortcut("f", modifiers: [.command, .shift])
        case .archive: return KeyboardShortcut("e")
        case .readToggle: return KeyboardShortcut("u", modifiers: [.command, .shift])
        case .flagToggle: return KeyboardShortcut("l", modifiers: [.command, .shift])
        case .snooze: return KeyboardShortcut("s", modifiers: [.command, .control])
        case .junkToggle: return KeyboardShortcut("j", modifiers: [.command, .shift])
        case .delete: return KeyboardShortcut(.delete, modifiers: [])
        case .editDraft, .move, .deleteAllFromSender: return nil
        }
    }
}

/// The list's selection colours. The table's own grey wash is off, so each selected row has
/// exactly one highlight: this one. The other rows of a selection also have a thin accent
/// outline, about 3.4:1 against the list in either appearance, so they show clearly.
enum MailListWash {
    /// The accent's strength behind the message on screen and behind the other selected rows.
    static let focusedOpacity = 0.26
    static let memberOpacity = 0.16
    /// Text that is quiet on an unselected row, on a selected one: 5.5:1 or more on the light
    /// washes and 5:1 or more on the dark ones (see `MailListContrastTests`).
    static let selectedTextOpacity = 0.75

    /// The label colour's strength for a row's quieter lines on an unselected row. The label
    /// colour is about 85% black or white, so these give 4.5:1 or more on the list in light and
    /// dark appearance (see `MailListContrastTests`). Sender, then subject, then preview, and read
    /// rows quieter than unread ones.
    static let readSubject = 0.82
    static let unreadPreview = 0.78
    static let readPreview = 0.70

    static func color(_ highlight: MailRowHighlight) -> Color {
        switch highlight {
        case .none: return .clear
        case .focused: return Color.accentColor.opacity(focusedOpacity)
        case .member: return Color.accentColor.opacity(memberOpacity)
        }
    }

    /// The style of a row's secondary text, such as the date and the preview. `quiet` is the
    /// unselected row's own style; a selected row uses one that reads on its wash.
    static func text(_ highlight: MailRowHighlight, quiet: HierarchicalShapeStyle) -> AnyShapeStyle {
        highlight == .none ? AnyShapeStyle(quiet) : AnyShapeStyle(Color.primary.opacity(selectedTextOpacity))
    }

    /// The style of a quieter line drawn at `opacity` of the label colour on an unselected row.
    static func text(_ highlight: MailRowHighlight, opacity: Double) -> AnyShapeStyle {
        highlight == .none ? AnyShapeStyle(Color.primary.opacity(opacity)) : AnyShapeStyle(Color.primary.opacity(selectedTextOpacity))
    }

    /// The rounded wash behind a selected row, inset from the column's edges like the sidebar's.
    static func background(_ highlight: MailRowHighlight) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return shape.fill(color(highlight))
            .overlay { if highlight == .member { shape.strokeBorder(Color.accentColor, lineWidth: 1) } }
            .padding(.horizontal, 10)
    }
}

/// Archive, Delete, and Read or Unread over the end of a row's first line, while the pointer is on
/// the row. The row keeps its date underneath; the buttons' background fades into the row.
struct MailRowHoverBar: View {
    let actions: [MailRowAction]
    let unread: Bool
    let selection: MailRowHighlight
    let act: (MailRowAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions, id: \.self) { action in
                Button { act(action) } label: {
                    Image(systemName: action == .readToggle ? (unread ? "envelope.open" : "envelope.badge") : action.symbol)
                }
                .help(action.help(unread: unread))
                .accessibilityLabel(action.hoverTitle(unread: unread))
            }
        }
        .buttonStyle(MailIconButtonStyle()).font(.system(size: 12))
        .padding(.leading, 22)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                MailListWash.color(selection)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                                 startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// A quiet date label above a run of rows: Today, Yesterday, This Week, a month, or a year.
/// It is a row of its own that cannot be selected, and it does not stick to the top.
struct MailDateSectionLabel: View {
    let section: MailDateSection
    var body: some View {
        Text(section.title())
            .font(.system(size: MailStyle.meta, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8).padding(.leading, 15)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A snapshot run shows one row's buttons as if the pointer were on it.
private struct MailRowHoverPreviewKey: EnvironmentKey {
    static let defaultValue: Int64? = nil
}

extension EnvironmentValues {
    var mailRowHoverPreview: Int64? {
        get { self[MailRowHoverPreviewKey.self] }
        set { self[MailRowHoverPreviewKey.self] = newValue }
    }
}

/// Turns off the table's own grey selection under a SwiftUI List, so the rows' accent wash is
/// the only highlight. Clicks, ⌘-click, and ⇧-click still select as before.
struct MailListPlainSelection: NSViewRepresentable {
    /// Receives the list's table, so a selection change can be checked against it.
    var found: MailListTable?

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        found?.probe = probe
        probe.watcher = found
        return probe
    }
    func updateNSView(_ view: Probe, context: Context) { found?.probe = view; view.watcher = found; view.apply() }

    final class Probe: NSView {
        /// Watches clicks on the one selected row, which change no selection. See `MailListTable`.
        private var clicks: Any?
        weak var watcher: MailListTable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if let clicks { NSEvent.removeMonitor(clicks); self.clicks = nil }
            guard window != nil else { return }
            clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if let self, let table = self.nearestTable(), MailListTable.isPlainClickOnTheSelectedRow(event, in: table) {
                    // After the table has handled the click, as a selection change would be.
                    DispatchQueue.main.async { [weak self] in self?.watcher?.clickedSelectedRow?() }
                }
                return event
            }
        }

        // The list's place is known only once this view has its size.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if !newSize.equalTo(.zero) { apply() }
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let table = self?.nearestTable(), table.selectionHighlightStyle != .none else { return }
                table.selectionHighlightStyle = .none
            }
        }

        /// The message list's own table: the one whose scroll view lies under this view, which
        /// sits behind the list. A table elsewhere in the window, such as the sidebar's, never matches.
        func nearestTable() -> NSTableView? {
            let frame = convert(bounds, to: nil)
            guard window != nil, !frame.isEmpty else { return nil }
            var ancestor = superview
            while let view = ancestor {
                if let table = Self.tables(in: view).first(where: { Self.table($0, covers: frame) }) { return table }
                ancestor = view.superview
            }
            return nil
        }

        /// True when `table` scrolls in a view that holds the centre of `frame`, in window points.
        static func table(_ table: NSTableView, covers frame: NSRect) -> Bool {
            guard let scroll = table.enclosingScrollView else { return false }
            return scroll.convert(scroll.bounds, to: nil).contains(NSPoint(x: frame.midX, y: frame.midY))
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
    }
}

/// The message list's own table, once found. A selection change counts as yours only when the
/// click or key that made it was in this table.
final class MailListTable {
    weak var probe: MailListPlainSelection.Probe?
    /// Looked up when asked, so it is there as soon as the list is on screen.
    var view: NSTableView? { probe?.nearestTable() }
    /// A plain click on the row that is already the only selected one. It changes no selection,
    /// so the list's selection does not report it; the page shows that row again.
    var clickedSelectedRow: (() -> Void)?

    /// True for a single plain click, in `table`, on the row that is its only selected row. No
    /// SwiftUI gesture is put on the rows: one takes the click from the table, and then a click
    /// selects nothing.
    static func isPlainClickOnTheSelectedRow(_ event: NSEvent, in table: NSTableView) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
              let window = table.window, event.window === window, table.selectedRowIndexes.count == 1 else { return false }
        let point = table.convert(event.locationInWindow, from: nil)
        guard table.visibleRect.contains(point) else { return false }
        let row = table.row(at: point)
        return row >= 0 && table.selectedRowIndexes.contains(row)
    }
}
