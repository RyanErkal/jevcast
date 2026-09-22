import AppKit
import Quartz

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FilePreview {
    private var panel: NSPanel?
    private var preview: QLPreviewView?
    var isVisible: Bool { panel?.isVisible == true }

    func toggle(path: String?, beside parent: NSWindow) {
        if isVisible { close(); return }
        guard let path else { return }
        let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                                 styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = URL(fileURLWithPath: path).lastPathComponent
        panel.isReleasedWhenClosed = false
        panel.level = parent.level
        guard let preview = QLPreviewView(frame: panel.contentView!.bounds, style: .normal) else { return }
        preview.autoresizingMask = [.width, .height]
        preview.autostarts = false
        preview.previewItem = NSURL(fileURLWithPath: path)
        panel.contentView = preview
        let screen = parent.screen?.visibleFrame ?? parent.frame
        let right = parent.frame.maxX + 12
        let x = right + panel.frame.width <= screen.maxX ? right : max(screen.minX, parent.frame.minX - panel.frame.width - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: max(screen.minY, parent.frame.midY - 250)))
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.preview = preview; self.panel = panel
    }
    func update(path: String?) {
        guard isVisible else { return }
        guard let path else { close(); return }
        preview?.previewItem = NSURL(fileURLWithPath: path)
        panel?.title = URL(fileURLWithPath: path).lastPathComponent
    }
    func close() {
        preview?.close()
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        preview = nil; panel = nil
    }
}

@MainActor
final class ResultActions {
    private var callbacks: [() -> Void] = []
    private var activeMenu: NSMenu?
    private var performedAction = false
    private var dismissedByOwner = false
    func dismiss() {
        dismissedByOwner = true
        activeMenu?.cancelTrackingWithoutAnimation()
    }
    func show(model: LauncherModel, in view: NSView, at point: NSPoint, preview: @escaping () -> Void, dismissed: () -> Void) {
        guard let result = model.selected else { return }
        // Pause recognition so the menu always acts on the row the user opened.
        model.pauseListening()
        let menu = NSMenu()
        callbacks = []; performedAction = false; dismissedByOwner = false; activeMenu = menu
        func add(_ title: String, key: String = "", action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: key)
            item.target = self; item.tag = callbacks.count
            callbacks.append { model.select(result.id); action() }; menu.addItem(item)
        }
        add(model.primaryActionTitle ?? "Open", key: "\r") { model.execute() }
        if result.path != nil {
            add("Quick Look", key: "y", action: preview)
            add("Reveal in Finder", key: "r") { model.revealSelected() }
            add("Copy Path") { model.copyPath() }
        }
        switch result.action {
        case .clipboard(let item):
            add("Paste", key: "\r") { model.execute(paste: true) }
            menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = [.shift]
            add(item.pinned ? "Unpin" : "Pin") { model.clipboard.togglePin(item.id); model.rebuild() }
        case .copy, .snippet:
            add("Paste", key: "\r") { model.execute(paste: true) }
            menu.item(at: menu.numberOfItems - 1)?.keyEquivalentModifierMask = [.shift]
        case .stopProcess(let listener):
            let details = model.portDetails[listener.pid]
            add("Open http://localhost:\(listener.port)") {
                if let url = URL(string: "http://localhost:\(listener.port)") { NSWorkspace.shared.open(url) }
                model.onClose?(false)
            }
            if let folder = details?.folder {
                add("Show Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]); model.onClose?(false)
                }
            }
            menu.addItem(.separator())
            if model.portOwner(listener) == .otherUser {
                add("Copy sudo kill \(listener.pid)") { model.copy("sudo kill \(listener.pid)"); model.message = "Command copied. Paste it in Terminal." }
            } else {
                add("Force Stop") { model.forceStop(listener) }
            }
            add("Copy PID") { model.copy(String(listener.pid)); model.message = "PID copied" }
            if let arguments = details?.arguments, !arguments.isEmpty {
                add("Copy Command Line") { model.copy(arguments); model.message = "Command line copied" }
            }
        default: break
        }
        if case .app = result.action {
            menu.addItem(.separator())
            add(model.preferences.favourites.contains(result.id) ? "Remove Favourite" : "Add Favourite") {
                model.preferences.toggleFavourite(result.id); model.rebuild()
            }
        }
        menu.popUp(positioning: nil, at: point, in: view)
        activeMenu = nil; callbacks = []
        if !performedAction && !dismissedByOwner { dismissed() }
    }
    @objc private func invoke(_ item: NSMenuItem) {
        guard callbacks.indices.contains(item.tag) else { return }
        performedAction = true
        callbacks[item.tag]()
    }
}
