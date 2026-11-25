import Foundation

/// Widths of Mail's columns in the panel: the mailbox sidebar, the message list, and the reader,
/// which takes the rest. Without a width you chose, the sidebar and list follow the panel's
/// width and the reading setting. A width you drag to replaces that until you reset it. Every
/// width is clamped, so the reader keeps at least `readerMinimum` points from the smallest panel
/// (860) to the largest (1320).
public struct MailColumnLayout: Equatable, Sendable {
    /// Zero while the sidebar is hidden.
    public let sidebar: Double
    public let list: Double
    public let reader: Double

    public static let sidebarRange = 160.0...320.0
    public static let listRange = 240.0...560.0
    /// The reader's width at the smallest panel with the default columns, rounded down.
    public static let readerMinimum = 420.0
    public static let dividerWidth = 1.0

    /// The sidebar's width when you have not chosen one.
    public static func defaultSidebar(total: Double) -> Double { min(205, max(190, (total * 0.155).rounded())) }

    /// The list's width when you have not chosen one: `fraction` of what the sidebar leaves.
    public static func defaultList(total: Double, sidebar: Double, fraction: Double) -> Double {
        min(380, max(240, ((total - sidebar) * fraction).rounded()))
    }

    /// The columns for a panel `total` points wide. A custom width replaces the default.
    public static func resolve(total: Double, showsSidebar: Bool, listFraction: Double,
                               customSidebar: Double? = nil, customList: Double? = nil) -> MailColumnLayout {
        let sidebar = showsSidebar ? clampSidebar(customSidebar ?? defaultSidebar(total: total), total: total) : 0
        let list = clampList(customList ?? defaultList(total: total, sidebar: sidebar, fraction: listFraction),
                             total: total, sidebar: sidebar)
        let dividers = (showsSidebar ? 2 : 1) * dividerWidth
        return MailColumnLayout(sidebar: sidebar, list: list, reader: max(0, total - sidebar - list - dividers))
    }

    /// A sidebar width inside its range, leaving the narrowest list and the reader's minimum.
    public static func clampSidebar(_ proposed: Double, total: Double) -> Double {
        let most = total - listRange.lowerBound - readerMinimum - 2 * dividerWidth
        return clamp(proposed, low: sidebarRange.lowerBound, high: min(sidebarRange.upperBound, most))
    }

    /// A list width inside its range, leaving the reader's minimum beside `sidebar`.
    public static func clampList(_ proposed: Double, total: Double, sidebar: Double) -> Double {
        let dividers = (sidebar > 0 ? 2 : 1) * dividerWidth
        let most = total - sidebar - readerMinimum - dividers
        return clamp(proposed, low: listRange.lowerBound, high: min(listRange.upperBound, most))
    }

    /// Whole points, and never below `low`, even in a panel too narrow for every minimum.
    private static func clamp(_ value: Double, low: Double, high: Double) -> Double {
        max(low, min(max(low, high), value.rounded()))
    }
}
