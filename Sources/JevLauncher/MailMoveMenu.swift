import AppKit
import LauncherCore

/// The folders the selected message can move to, as a menu opened from the keyboard (⇧⌘M).
/// Typing a folder's first letters selects it, and Return moves the message.
@MainActor
enum MailMoveMenu {
    private final class Target: NSObject {
        var pick: ((Int64) -> Void)?
        @objc func choose(_ item: NSMenuItem) { if let id = item.representedObject as? Int64 { pick?(id) } }
    }
    private static let target = Target()

    static func show(_ model: MailModel) {
        let destinations = model.moveDestinations
        guard !destinations.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        let menu = NSMenu(title: "Move To")
        let header = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for box in destinations {
            let item = NSMenuItem(title: box.path, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = box.rowID
            menu.addItem(item)
        }
        target.pick = { [weak model] id in
            guard let model, let box = model.moveDestinations.first(where: { $0.rowID == id }) else { return }
            model.move(to: box)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX - 110, y: view.bounds.midY + 80), in: view)
    }
}
