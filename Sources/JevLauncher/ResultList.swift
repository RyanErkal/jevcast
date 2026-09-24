import AppKit
import SwiftUI

/// Native row reuse and scroll-to-visible keep incremental search updates steady.
struct ResultList: NSViewRepresentable {
    @ObservedObject var model: LauncherModel
    let actions: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, actions: actions) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsTable()
        table.contextAction = { [weak coordinator = context.coordinator] row in
            guard let coordinator, let result = coordinator.result(at: row), result.isCurrent else { return }
            coordinator.model.select(result.id)
            coordinator.actions()
        }
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
        table.headerView = nil
        // Heights come from the delegate: section labels, single-line, and two-line rows differ.
        // NSTableView adds intercell spacing to each row, so the pitch is cell + spacing.
        table.rowHeight = LauncherMetrics.cellHeight
        table.intercellSpacing = NSSize(width: 0, height: LauncherMetrics.rowSpacing)
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        // One click runs a row, as in Spotlight. Hovering highlights the row under the pointer.
        table.action = #selector(Coordinator.runRow)
        table.hoverAction = { [weak coordinator = context.coordinator] row in
            guard let coordinator, let result = coordinator.result(at: row), result.isCurrent,
                  coordinator.model.selectedID != result.id else { return }
            coordinator.selectedByPointer = true
            coordinator.model.select(result.id)
        }
        table.setAccessibilityLabel("Search Results")
        table.setAccessibilityIdentifier("launcher-results")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = table
        context.coordinator.table = table
        model.selectedRowRect = { [weak table, weak coordinator = context.coordinator] in
            guard let table, let coordinator, let index = coordinator.index(of: coordinator.model.selectedID) else { return nil }
            return table.convert(table.rect(ofRow: index), to: nil)
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let trace = PerformanceTrace.start("ResultTable")
        defer { PerformanceTrace.end("ResultTable", trace) }
        let coordinator = context.coordinator
        guard let table = coordinator.table else { return }
        let signature = model.rows.map { row -> String in
            guard let result = row.result else { return row.id }
            return result.id + "\n" + result.title + "\n" + result.detail + String(result.isCurrent)
        }
        coordinator.updating = true
        coordinator.rows = model.rows
        if coordinator.signature != signature {
            coordinator.signature = signature
            table.reloadData()
        }
        let index = coordinator.index(of: model.selectedID)
        table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        if let index, coordinator.lastSelectedID != model.selectedID, !coordinator.selectedByPointer {
            // Keep the section label in view above the first row of a group.
            if index > 0, case .section = coordinator.rows[index - 1] { table.scrollRowToVisible(index - 1) }
            table.scrollRowToVisible(index)
        }
        coordinator.lastSelectedID = model.selectedID
        coordinator.selectedByPointer = false
        coordinator.updating = false
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: LauncherModel
        let actions: () -> Void
        weak var table: NSTableView?
        var rows: [LauncherRow] = []
        var signature: [String] = []
        var lastSelectedID: String?
        var updating = false
        /// True when the pointer chose the selection. That row is already in view, so the
        /// table does not scroll, and a scrolled list never snaps back.
        var selectedByPointer = false
        init(model: LauncherModel, actions: @escaping () -> Void) { self.model = model; self.actions = actions }
        func result(at row: Int) -> LauncherResult? { rows.indices.contains(row) ? rows[row].result : nil }
        func index(of id: String?) -> Int? {
            guard let id else { return nil }
            return rows.firstIndex { $0.result?.id == id }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows.indices.contains(row) ? rows[row].height : LauncherMetrics.cellHeight
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch rows[row] {
            case .section(let group):
                let id = NSUserInterfaceItemIdentifier("section-cell")
                let cell = tableView.makeView(withIdentifier: id, owner: self) as? SectionCell ?? SectionCell()
                cell.identifier = id
                cell.configure(group.title)
                return cell
            case .result(let result):
                let id = NSUserInterfaceItemIdentifier(result.isTwoLine ? "result-cell-tall" : "result-cell")
                let cell = tableView.makeView(withIdentifier: id, owner: self) as? ResultCell ?? ResultCell(twoLine: result.isTwoLine)
                cell.identifier = id
                cell.configure(result)
                return cell
            }
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { result(at: row)?.isCurrent ?? false }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, let result = result(at: table.selectedRow) else { return }
            model.select(result.id)
        }
        @objc func runRow() {
            // A click on a section label or empty space does nothing. The second click of a double-click
            // is ignored, so a row that asks for confirmation always needs a separate click.
            guard (NSApp.currentEvent?.clickCount ?? 1) <= 1 else { return }
            guard let table, table.clickedRow >= 0, let result = result(at: table.clickedRow), result.isCurrent else { return }
            model.select(result.id); model.execute()
        }
    }
}

private final class ResultsTable: NSTableView {
    var contextAction: ((Int) -> Void)?
    var hoverAction: ((Int) -> Void)?
    private var hoverArea: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }
    /// The launcher panel never activates the app, so hover help must show while it is inactive.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.allowsToolTipsWhenApplicationIsInactive = true
    }
    /// The first click works even when the panel was not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    /// Only real pointer movement selects, so a resting pointer never fights the arrow keys.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { hoverAction?(row) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { contextAction?(row) }
        return nil
    }
}

/// Neutral rounded wash for the selected row, as in Spotlight and Raycast:
/// white at 10% in a dark appearance, black at 6% in a light one. The row
/// includes the table's row spacing, so the wash insets by half of it.
private final class ResultRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 0, dy: LauncherMetrics.rowSpacing / 2)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.06)).setFill()
        NSBezierPath(roundedRect: inset, xRadius: LauncherMetrics.highlightRadius, yRadius: LauncherMetrics.highlightRadius).fill()
    }
}

/// Small tertiary group label, such as "Applications". Not selectable.
private final class SectionCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: LauncherMetrics.sectionLabelSize, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LauncherMetrics.cellInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }
}

/// Single-line: icon, title, and a trailing accessory. Two-line: icon, title
/// over subtitle, for calculator answers and clipboard entries.
private final class ResultCell: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let twoLine: Bool
    private var representedID = ""
    private var isStale = false
    private var showsSymbol = true
    init(twoLine: Bool) {
        self.twoLine = twoLine
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: LauncherMetrics.titleSize)
        detailLabel.font = .systemFont(ofSize: twoLine ? LauncherMetrics.subtitleSize : LauncherMetrics.accessorySize)
        titleLabel.lineBreakMode = twoLine ? .byTruncatingTail : .byTruncatingMiddle
        detailLabel.lineBreakMode = .byTruncatingMiddle
        icon.imageScaling = .scaleProportionallyDown
        for view in [icon, titleLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = LauncherMetrics.cellInset
        var constraints = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: LauncherMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: LauncherMetrics.iconSize),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: LauncherMetrics.iconSpacing)
        ]
        if twoLine {
            let text = NSLayoutGuide()
            addLayoutGuide(text)
            constraints += [
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.topAnchor.constraint(equalTo: text.topAnchor),
                detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
                detailLabel.bottomAnchor.constraint(equalTo: text.bottomAnchor),
                detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset)
            ]
        } else {
            // The title keeps its width first; a long accessory truncates in the middle.
            titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            detailLabel.alignment = .right
            let minimumAccessory = detailLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
            minimumAccessory.priority = .init(760)
            constraints += [
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                minimumAccessory
            ]
        }
        NSLayoutConstraint.activate(constraints)
        textField = titleLabel
        imageView = icon
        applyColors()
    }
    override init(frame frameRect: NSRect) { fatalError("Use init(twoLine:)") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Selection is a neutral wash, so text keeps its normal colours on the
    /// selected row: the table's emphasized style never reaches the labels.
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { super.backgroundStyle = .normal }
    }
    private func applyColors() {
        titleLabel.textColor = isStale ? .tertiaryLabelColor : .labelColor
        detailLabel.textColor = twoLine && !isStale ? .secondaryLabelColor : .tertiaryLabelColor
        icon.contentTintColor = showsSymbol ? .secondaryLabelColor : nil
        icon.alphaValue = isStale ? 0.5 : 1
    }
    func configure(_ result: LauncherResult) {
        representedID = result.id
        isStale = !result.isCurrent
        titleLabel.stringValue = result.title
        detailLabel.stringValue = result.detail
        detailLabel.isHidden = result.detail.isEmpty
        showsSymbol = true
        icon.image = NSImage(systemSymbolName: result.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: LauncherMetrics.symbolPointSize, weight: .regular))
        setAccessibilityElement(true)
        setAccessibilityLabel(result.detail.isEmpty ? result.title : result.title + ", " + result.detail)
        setAccessibilityIdentifier(result.id)
        toolTip = result.help
        setAccessibilityHelp(result.help)
        // A Jev badge leads the accessory, so its end truncates and the badge stays whole.
        detailLabel.lineBreakMode = twoLine || result.help != nil ? .byTruncatingTail : .byTruncatingMiddle
        if let path = result.path {
            IconCache.shared.load(path) { [weak self] image in
                guard let self, self.representedID == result.id else { return }
                self.showsSymbol = false
                self.icon.image = image
                self.applyColors()
            }
        }
        applyColors()
    }
}

/// Icon disk reads do not hold up typing or the first panel frame.
private final class IconCache: @unchecked Sendable {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "JevLauncher.icons", qos: .utility)
    func load(_ path: String, completion: @escaping (NSImage) -> Void) {
        if let image = cache.object(forKey: path as NSString) { completion(image); return }
        queue.async { [self] in
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: LauncherMetrics.iconSize, height: LauncherMetrics.iconSize)
            cache.setObject(image, forKey: path as NSString)
            DispatchQueue.main.async { completion(image) }
        }
    }
}
