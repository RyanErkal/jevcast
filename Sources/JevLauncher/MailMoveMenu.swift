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
        guard !model.refuses(.move) else { return }
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
        // Only what the message's mailbox allows, by the same rule as the row menu.
        func allows(_ action: MailRowAction) -> Bool { selected && model.refusal(action, multiple: action == .delete && model.selectedConversationRowIDs.count > 1) == nil }
        add("Reply", "⌘R", enabled: allows(.reply)) { model.reply(all: false) }
        add("Reply All", "⇧⌘R", enabled: allows(.replyAll)) { model.reply(all: true) }
        add("Forward", "⇧⌘F", enabled: allows(.forward)) { model.forward() }
        menu.addItem(.separator())
        add("Archive", "⌘E", enabled: allows(.archive)) { model.archive() }
        add("Snooze…", "⌃⌘S", enabled: allows(.snooze)) { page.openSnooze() }
        add("Move to Folder…", "⇧⌘M", enabled: allows(.move) && !model.moveDestinations.isEmpty) { MailMoveMenu.show(model) }
        add("Delete", "⌫", enabled: allows(.delete)) { model.delete() }
        add(model.selectedIsJunk ? "Not Junk" : "Mark as Junk", "⇧⌘J", enabled: allows(.junkToggle)) { model.setJunk(!model.selectedIsJunk) }
        menu.addItem(.separator())
        add(model.selected?.flagged == true ? "Unflag" : "Flag", "⇧⌘L", enabled: allows(.flagToggle)) { model.toggleFlag() }
        add(model.selected?.read == false ? "Mark as Read" : "Mark as Unread", "⇧⌘U", enabled: allows(.readToggle)) { model.toggleRead() }
        add(page.expanded ? "Show the List" : "Expand the Message", page.expanded ? "esc" : "↩", enabled: selected) {
            if !page.expanded { model.noteUserAction() }
            page.expanded.toggle()
        }
        // The ••• of a conversation is inside the page, where the keys do not reach.
        if selected, model.shownThread != nil {
            add(MailReaderToolbarItem.quotedTextTitle(shown: model.quotesShown), "") { model.toggleQuotedText() }
        }
        add("Larger Text", "⌘+") { MailReading.zoom = MailReading.zoom(MailReading.zoom, .larger) }
        add("Smaller Text", "⌘−") { MailReading.zoom = MailReading.zoom(MailReading.zoom, .smaller) }
        add("Actual Size", "⌘0") { MailReading.zoom = 1 }
        menu.addItem(.separator())
        add("New Message", "⌘N") { model.compose() }
        add("Undo", "⌘Z", enabled: model.lastChange != nil || model.pendingSend != nil) {
            if model.pendingSend != nil { model.undoSend() } else { model.undoLastChange() }
        }
        if page.features != nil {
            // The settings pages, also while the sidebar and its gear are hidden.
            menu.addItem(.separator())
            let settings = NSMenu(title: "Mail Settings")
            for tool in MailTool.allCases {
                let item = NSMenuItem(title: tool.rawValue, action: #selector(Target.run(_:)), keyEquivalent: "")
                item.target = target; item.tag = target.actions.count
                target.actions.append { page.openTool(tool) }
                settings.addItem(item)
            }
            let parent = NSMenuItem(title: "Mail Settings", action: nil, keyEquivalent: "")
            parent.submenu = settings
            menu.addItem(parent)
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
