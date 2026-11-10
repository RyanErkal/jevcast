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

/// Every action for the selected message, with its key, opened with ⌘K. The footer shows only the
/// most used keys; this lists the rest.
@MainActor
enum MailActionsMenu {
    private final class Target: NSObject {
        var actions: [() -> Void] = []
        @objc func run(_ item: NSMenuItem) { if actions.indices.contains(item.tag) { actions[item.tag]() } }
    }
    private static let target = Target()

    static func show(_ page: MailPage, _ model: MailModel) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let menu = NSMenu(title: "Actions")
        target.actions = []
        func add(_ title: String, _ key: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: enabled ? #selector(Target.run(_:)) : nil, keyEquivalent: "")
            item.target = target; item.tag = target.actions.count; item.isEnabled = enabled
            // The key is shown, not bound: the page already handles it.
            if !key.isEmpty {
                item.attributedTitle = NSAttributedString(string: title + "\t" + key, attributes: [.paragraphStyle: tabs])
            }
            target.actions.append(action)
            menu.addItem(item)
        }
        let selected = model.selected != nil && model.place != .outbox
        add("Reply", "⌘R", enabled: selected) { model.reply(all: false) }
        add("Reply All", "⇧⌘R", enabled: selected) { model.reply(all: true) }
        add("Forward", "⇧⌘F", enabled: selected) { model.forward() }
        menu.addItem(.separator())
        add("Archive", "⌃⌘A", enabled: selected) { model.archive() }
        add("Move to Folder…", "⇧⌘M", enabled: selected && !model.moveDestinations.isEmpty) { MailMoveMenu.show(model) }
        add("Delete", "⌫", enabled: selected) { model.delete() }
        add(model.selectedIsJunk ? "Not Junk" : "Mark as Junk", "⇧⌘J", enabled: selected) { model.setJunk(!model.selectedIsJunk) }
        menu.addItem(.separator())
        add(model.selected?.flagged == true ? "Unflag" : "Flag", "⇧⌘L", enabled: selected) { model.toggleFlag() }
        add(model.selected?.read == false ? "Mark as Read" : "Mark as Unread", "⇧⌘U", enabled: selected) { model.toggleRead() }
        add(page.expanded ? "Show the List" : "Expand the Message", "Space", enabled: selected) { page.expanded.toggle() }
        menu.addItem(.separator())
        add("New Message", "⌘N") { model.compose() }
        add("Undo", "⌘Z", enabled: model.lastChange != nil || model.pendingSend != nil) {
            if model.pendingSend != nil { model.undoSend() } else { model.undoLastChange() }
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 300, y: 44), in: view)
    }

    private static let tabs: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
        return style
    }()
}
