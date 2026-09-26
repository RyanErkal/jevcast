import AppKit
import LauncherCore

/// The ⌘K menu for the Clipboard view.
@MainActor
final class ClipboardActions: NSObject {
    private var callbacks: [() -> Void] = []
    private var menu: NSMenu?
    var isShowing: Bool { menu != nil }

    func dismiss() { menu?.cancelTrackingWithoutAnimation() }

    func show(for entry: ClipEntry, count: Int, page: ClipboardPage, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        callbacks = []
        func add(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], to target: NSMenu? = nil, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self; item.tag = callbacks.count
            callbacks.append(action)
            (target ?? menu).addItem(item)
        }
        let entries = page.selectedEntries
        let several = count > 1
        add(several ? "Copy \(count) Entries" : "Copy", "\r") { page.copy(entries) }
        add(several ? "Paste \(count) Entries" : "Paste", "\r", [.shift]) { page.paste(entries, plain: false) }
        if entries.contains(where: { $0.kind.isText || $0.ocrText != nil }) {
            add("Paste as Plain Text", "\r", [.option]) { page.paste(entries, plain: true) }
        }
        add(entries.contains { !$0.pinned } ? "Pin" : "Unpin", "p", [.command]) { page.togglePin() }
        add(several ? "Delete \(count) Entries" : "Delete", "\u{8}", []) { page.delete() }
        guard !several else { popUp(menu, in: view); return }

        menu.addItem(.separator())
        if let text = entry.ocrText {
            add("Copy Text from Image") { page.copyNew(text, message: "Text from the image copied.") }
        }
        if entry.isImage { add("Save Image to Downloads") { page.saveImageToDownloads() } }
        switch entry.kind {
        case .files:
            add("Open") { page.open(entry) }
            add("Show in Finder") { page.reveal(entry) }
        case .link:
            add("Open Link") { page.open(entry) }
            if let url = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let label = entry.linkHost ?? url
                add("Copy as Markdown Link") { page.copyNew("[\(label)](\(url))", message: "Markdown link copied.") }
            }
        default: break
        }
        add("Quick Look", " ") { page.toggleQuickLook() }
        if entry.kind.isText {
            menu.addItem(.separator())
            let transforms = NSMenu()
            let groups: [[ClipTransform]] = [
                [.uppercase, .lowercase, .titleCase],
                [.trim, .removeLineBreaks, .sortLines, .removeDuplicateLines],
                [.jsonPretty, .jsonMinify],
                [.urlEncode, .urlDecode, .base64Encode, .base64Decode],
                [.count]
            ]
            for (index, group) in groups.enumerated() {
                if index > 0 { transforms.addItem(.separator()) }
                for transform in group { add(transform.title, to: transforms) { page.transform(transform) } }
            }
            let item = NSMenuItem(title: "Transform Text", action: nil, keyEquivalent: "")
            item.submenu = transforms
            menu.addItem(item)
        }
        popUp(menu, in: view)
    }

    private func popUp(_ menu: NSMenu, in view: NSView) {
        self.menu = menu
        let point = NSPoint(x: view.bounds.maxX - 260, y: view.isFlipped ? 60 : view.bounds.maxY - 60)
        menu.popUp(positioning: nil, at: point, in: view)
        self.menu = nil
        callbacks = []
    }

    @objc private func invoke(_ item: NSMenuItem) {
        guard callbacks.indices.contains(item.tag) else { return }
        let action = callbacks[item.tag]
        // Runs after the menu closes, so a paste reaches the app in front.
        DispatchQueue.main.async { action() }
    }
}
