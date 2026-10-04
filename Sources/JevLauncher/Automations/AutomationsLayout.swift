import AppKit
import SwiftUI

/// Column widths for the Automations window. Widths come from the space there is, so a small window never
/// squeezes a column below the size its content needs: the sidebar hides first, then the list and the
/// detail take turns in one column.
enum AutomationsLayout {
    static let sidebarWidth: CGFloat = 220
    static let listMinimum: CGFloat = 260
    static let listMaximum: CGFloat = 380
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

    static func sidebarFits(windowWidth: CGFloat) -> Bool { windowWidth >= sidebarFitsWidth }
}

/// A list beside its detail, or one at a time when the space is too narrow for both. In one column, choosing
/// an item shows its detail; Back (⌘[) returns to the list with the same item still chosen.
struct ResponsiveSplit<ListContent: View, DetailContent: View>: View {
    /// The chosen item's ID; nil shows the list in one column.
    let selection: String?
    let listTitle: String
    @ViewBuilder var list: (@escaping () -> Void) -> ListContent
    @ViewBuilder var detail: () -> DetailContent
    @State private var showsList = false

    var body: some View {
        GeometryReader { geometry in
            switch AutomationsLayout.columns(width: geometry.size.width) {
            case .split(let width):
                HStack(spacing: 0) {
                    list { showsList = false }.frame(width: width)
                    Divider()
                    detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .stacked:
                if selection != nil, !showsList {
                    VStack(spacing: 0) {
                        HStack {
                            Button { showsList = true } label: { Label(listTitle, systemImage: "chevron.left") }
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
                    list { showsList = false }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: selection) { _, _ in showsList = false }
    }
}
