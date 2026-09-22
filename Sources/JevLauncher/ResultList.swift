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
            guard let coordinator, coordinator.rows.indices.contains(row) else { return }
            coordinator.model.select(coordinator.rows[row].id)
            coordinator.actions()
        }
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
        table.headerView = nil
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.runRow)
        table.setAccessibilityLabel("Search Results")
        table.setAccessibilityIdentifier("launcher-results")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let trace = PerformanceTrace.start("ResultTable")
        defer { PerformanceTrace.end("ResultTable", trace) }
        let coordinator = context.coordinator
        guard let table = coordinator.table else { return }
        let signature = model.results.map { $0.id + "\n" + $0.title + "\n" + $0.detail + String($0.isCurrent) }
        coordinator.updating = true
        coordinator.rows = model.results
        if coordinator.signature != signature {
            coordinator.signature = signature
            table.reloadData()
        }
        let index = model.results.firstIndex { $0.id == model.selectedID }
        table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        if let index, coordinator.lastSelectedID != model.selectedID {
            table.scrollRowToVisible(index)
        }
        coordinator.lastSelectedID = model.selectedID
        coordinator.updating = false
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: LauncherModel
        let actions: () -> Void
        weak var table: NSTableView?
        var rows: [LauncherResult] = []
        var signature: [String] = []
        var lastSelectedID: String?
        var updating = false
        init(model: LauncherModel, actions: @escaping () -> Void) { self.model = model; self.actions = actions }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("result-cell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? ResultCell ?? ResultCell()
            cell.identifier = id
            cell.configure(rows[row])
            return cell
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].isCurrent }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, rows.indices.contains(table.selectedRow) else { return }
            model.select(rows[table.selectedRow].id)
        }
        @objc func runRow() {
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            model.select(rows[table.clickedRow].id); model.execute()
        }
    }
}

private final class ResultsTable: NSTableView {
    var contextAction: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { contextAction?(row) }
        return nil
    }
}

private final class ResultCell: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var representedID = ""
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, detailLabel] { label.lineBreakMode = .byTruncatingMiddle }
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal; stack.spacing = 13; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        textField = titleLabel
        imageView = icon
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ result: LauncherResult) {
        representedID = result.id
        alphaValue = result.isCurrent ? 1 : 0.42
        titleLabel.stringValue = result.title
        detailLabel.stringValue = result.detail.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        icon.image = NSImage(systemSymbolName: result.symbol, accessibilityDescription: nil)
        setAccessibilityElement(true)
        setAccessibilityLabel(result.title + ", " + detailLabel.stringValue)
        setAccessibilityIdentifier(result.id)
        if case .app(let app) = result.action {
            AppIconCache.shared.load(app.path) { [weak self] image in
                guard let self, self.representedID == result.id else { return }
                self.icon.image = image
            }
        }
    }
}

/// Icon disk reads do not hold up typing or the first panel frame.
private final class AppIconCache: @unchecked Sendable {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "JevLauncher.icons", qos: .utility)
    func load(_ path: String, completion: @escaping (NSImage) -> Void) {
        if let image = cache.object(forKey: path as NSString) { completion(image); return }
        queue.async { [self] in
            let image = NSWorkspace.shared.icon(forFile: path)
            cache.setObject(image, forKey: path as NSString)
            DispatchQueue.main.async { completion(image) }
        }
    }
}
