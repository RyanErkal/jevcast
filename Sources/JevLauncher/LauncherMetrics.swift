import CoreGraphics

/// Launcher geometry. One 20pt gutter lines up the search glyph, section
/// labels, row icons, and footer; the query text and row titles start together.
///
/// Horizontal positions from the panel's leading edge:
/// - search glyph, section label, and row icon: `gutter` (20)
/// - query text and row title: `textLeading` (56)
/// - row highlight: `listInset` (8), so the icon sits `cellInset` (12) inside it
enum LauncherMetrics {
    static let gutter: CGFloat = 20
    /// Horizontal padding between the panel and the result table. The highlight fills the table width.
    static let listInset: CGFloat = 8
    /// Cell content inset from the table edge, so row content sits on the gutter.
    static var cellInset: CGFloat { gutter - listInset }
    /// Vertical padding above and below the result table.
    static let listPadding: CGFloat = 6

    /// Single-line row height (icon, title, accessory).
    static let cellHeight: CGFloat = 40
    /// Two-line row height, for calculator answers and clipboard entries.
    static let tallCellHeight: CGFloat = 48
    /// Section label row height.
    static let sectionHeight: CGFloat = 26
    /// Gap between highlights of adjacent rows. NSTableView adds it to each row.
    static let rowSpacing: CGFloat = 2
    /// Most single-line rows the list shows before it scrolls.
    static let maxVisibleRows = 8
    /// Tallest the list grows; longer lists scroll.
    static var maxListHeight: CGFloat { CGFloat(maxVisibleRows) * (cellHeight + rowSpacing) }

    /// Row icon frame; the search glyph uses the same width so the columns match.
    static let iconSize: CGFloat = 24
    static let symbolPointSize: CGFloat = 16
    static let iconSpacing: CGFloat = 12
    static var textLeading: CGFloat { gutter + iconSize + iconSpacing }
    static let titleSize: CGFloat = 14
    static let subtitleSize: CGFloat = 12
    static let accessorySize: CGFloat = 12
    static let sectionLabelSize: CGFloat = 11

    static let searchBarHeight: CGFloat = 52
    static let searchFontSize: CGFloat = 20
    static let searchGlyphSize: CGFloat = 19
    static let footerHeight: CGFloat = 36

    static let highlightRadius: CGFloat = 10
    static let panelRadius: CGFloat = 22
    static let panelBorderWidth: CGFloat = 0.5

    /// Key chip, shared by the footer and Settings.
    static let chipFontSize: CGFloat = 10
    static let chipRadius: CGFloat = 4
    static let chipPaddingX: CGFloat = 5
    static let chipPaddingY: CGFloat = 2
}
