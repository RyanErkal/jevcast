import AppKit
import SwiftUI

/// Column widths for the Automations window. Widths come from the space there is, so a small window never
/// squeezes a column below the size its content needs: the sidebar hides first, then the list and the
/// detail take turns in one column.
enum AutomationsLayout {
    static let sidebarWidth: CGFloat = 220
    static let listMinimum: CGFloat = 260
    static let listMaximum: CGFloat = 380
    /// The widest the list may be dragged. The detail keeps its minimum first.
    static let listDragMaximum: CGFloat = 440
    static let detailMinimum: CGFloat = 360
    /// The smallest window: the list and the detail side by side, without the sidebar.
    static let windowMinimum = NSSize(width: listMinimum + detailMinimum + 20, height: 480)
    /// Below this window width the sidebar hides by itself. The toolbar button still shows it.
    static let sidebarFitsWidth: CGFloat = sidebarWidth + listMinimum + detailMinimum + 60

    enum Columns: Equatable {
        /// The list at this width beside the detail.
        case split(list: CGFloat)
        /// One column: the list, or the chosen item with a way back.
        case stacked
    }

    /// The list takes about 38% of the width, within its limits, and always leaves the detail its minimum.
    static func columns(width: CGFloat) -> Columns {
        guard width >= listMinimum + detailMinimum + 1 else { return .stacked }
        let list = min(listMaximum, max(listMinimum, (width * 0.38).rounded()))
        return .split(list: min(list, width - detailMinimum - 1))
    }

    /// A list width the user dragged to, kept within its limits and always leaving the detail its minimum.
    static func draggedList(_ list: CGFloat, width: CGFloat) -> CGFloat {
        min(max(listMinimum, list.rounded()), min(listDragMaximum, width - detailMinimum - 1))
    }

    static func sidebarFits(windowWidth: CGFloat) -> Bool { windowWidth >= sidebarFitsWidth }
}

/// Which pane one column shows. Moving the selection, for example with the arrow keys, never changes it: the
/// list stays while the user browses. A click or Return opens the chosen item; Back returns to the list with
/// the same item still chosen, and choosing it again opens it again.
struct OneColumnState: Equatable {
    /// True while the chosen item's detail is open.
    var opened: Bool

    /// One column opens on the detail when an item is already chosen, as when the window opens on a run.
    init(selection: String?) { opened = selection != nil }

    func showsDetail(selection: String?) -> Bool { opened && selection != nil }
    /// A click on a row, which has just chosen its item.
    mutating func open() { opened = true }
    /// Return: opens the chosen item, if there is one. False when nothing is chosen.
    mutating func openChosen(_ selection: String?) -> Bool {
        guard selection != nil else { return false }
        opened = true
        return true
    }
    mutating func back() { opened = false }
    /// With nothing chosen the list shows, and stays when something is chosen next.
    mutating func selectionChanged(to selection: String?) { if selection == nil { opened = false } }
}

/// Lets the window's Return open the item chosen in a one-column list. The visible list registers itself.
@MainActor
final class OneColumnOpener {
    private var current: (token: UUID, open: () -> Bool)?

    func register(_ token: UUID, open: @escaping () -> Bool) { current = (token, open) }
    func unregister(_ token: UUID) { if current?.token == token { current = nil } }

    /// Opens the chosen item when a one-column list shows. False when no such list shows or nothing is chosen.
    func open() -> Bool { current?.open() ?? false }
}

private struct OneColumnOpenerKey: EnvironmentKey { static let defaultValue: OneColumnOpener? = nil }

extension EnvironmentValues {
    var oneColumnOpener: OneColumnOpener? {
        get { self[OneColumnOpenerKey.self] }
        set { self[OneColumnOpenerKey.self] = newValue }
    }
}

/// A list beside its detail, with a divider that drags, or one at a time when the space is too narrow for both.
/// In one column a click or Return opens the chosen item (`OneColumnState`); Back (⌘[) returns to the list.
struct ResponsiveSplit<ListContent: View, DetailContent: View>: View {
    /// The chosen item's ID; nil shows the list in one column.
    let selection: String?
    let listTitle: String
    @ViewBuilder var list: (@escaping () -> Void) -> ListContent
    @ViewBuilder var detail: () -> DetailContent
    @State private var oneColumn: OneColumnState
    /// The list width the user dragged to; nil follows the window.
    @State private var draggedList: CGFloat?
    @State private var dragStart: CGFloat?
    @State private var openerToken = UUID()
    @Environment(\.oneColumnOpener) private var opener

    init(selection: String?, listTitle: String, @ViewBuilder list: @escaping (@escaping () -> Void) -> ListContent,
         @ViewBuilder detail: @escaping () -> DetailContent) {
        self.selection = selection; self.listTitle = listTitle; self.list = list; self.detail = detail
        _oneColumn = State(initialValue: OneColumnState(selection: selection))
    }

    var body: some View {
        GeometryReader { geometry in
            switch AutomationsLayout.columns(width: geometry.size.width) {
            case .split(let automatic):
                let width = draggedList.map { AutomationsLayout.draggedList($0, width: geometry.size.width) } ?? automatic
                HStack(spacing: 0) {
                    list { oneColumn.open() }.frame(width: width)
                    divider(list: width, total: geometry.size.width)
                    detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .stacked:
                if oneColumn.showsDetail(selection: selection) {
                    VStack(spacing: 0) {
                        HStack {
                            Button { oneColumn.back() } label: { Label(listTitle, systemImage: "chevron.left") }
                                .buttonStyle(.borderless)
                                .keyboardShortcut("[", modifiers: .command)
                                .help("Back to the list (⌘[)")
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        Divider()
                        detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    list { oneColumn.open() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Only while this list shows; Return opens the item chosen now.
                        .onAppear { registerReturn(selection) }
                        .onChange(of: selection) { _, new in registerReturn(new) }
                        .onDisappear { opener?.unregister(openerToken) }
                }
            }
        }
        .onChange(of: selection) { _, new in oneColumn.selectionChanged(to: new) }
    }

    private func registerReturn(_ chosen: String?) {
        opener?.register(openerToken) { oneColumn.openChosen(chosen) }
    }

    /// The line between the list and the detail. Drag it to resize the list.
    private func divider(list width: CGFloat, total: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? width
                            dragStart = start
                            draggedList = AutomationsLayout.draggedList(start + drag.translation.width, width: total)
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }
}
