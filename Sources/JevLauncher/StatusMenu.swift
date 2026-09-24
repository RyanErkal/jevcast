import AppKit
import Combine

/// Menu-bar item. The menu is rebuilt each time it opens so the open/hide
/// label, the shortcut hint, voice toggle, permission ticks, and update stay current.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let preferences: Preferences
    private let updates: UpdateChecker
    private weak var commands: AppCommands?
    private let isOpen: () -> Bool
    private let toggle: () -> Void
    private var subscription: AnyCancellable?

    init(preferences: Preferences, updates: UpdateChecker, commands: AppCommands,
         isOpen: @escaping () -> Bool, toggle: @escaping () -> Void) {
        self.preferences = preferences; self.updates = updates; self.commands = commands
        self.isOpen = isOpen; self.toggle = toggle
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = AppIdentity.name
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        self.item = item
        subscription = updates.$state.sink { [weak self] state in
            if case .available = state { self?.setIcon(badged: true) } else { self?.setIcon(badged: false) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let commands else { return }
        if let release = updates.available {
            menu.addItem(withTitle: "Update Available: \(release.version)…", action: #selector(openUpdate), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let open = menu.addItem(withTitle: isOpen() ? "Hide \(AppIdentity.name)" : "Open \(AppIdentity.name)", action: #selector(toggleLauncher), keyEquivalent: preferences.hotkey.keyEquivalent)
        open.keyEquivalentModifierMask = preferences.hotkey.menuModifiers
        open.target = self
        let listen = menu.addItem(withTitle: "Listen When Opened", action: #selector(toggleVoice), keyEquivalent: "")
        listen.state = preferences.voiceEnabled ? .on : .off
        listen.target = self
        menu.addItem(.separator())

        let permissions = NSMenu()
        for permission in Permission.allCases {
            let entry = permissions.addItem(withTitle: permission.title, action: #selector(openPermission(_:)), keyEquivalent: "")
            entry.state = permission.isGranted ? .on : .off
            entry.toolTip = permission.purpose
            entry.representedObject = permission
            entry.target = self
        }
        permissions.addItem(.separator())
        permissions.addItem(withTitle: "Choose an item to open System Settings", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Permissions", action: nil, keyEquivalent: "").submenu = permissions

        menu.addItem(AppMenus.item("Settings…", #selector(AppCommands.showSettings), commands, key: ","))
        menu.addItem(AppMenus.item("Check for Updates…", #selector(AppCommands.checkForUpdates), commands))
        menu.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = AppMenus.helpMenu(commands: commands)
        menu.addItem(.separator())
        menu.addItem(AppMenus.item("About \(AppIdentity.name)", #selector(AppCommands.showAbout), commands))
        menu.addItem(withTitle: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// The sparkle, with a dot when an update is available. Template, so it follows the menu bar colour.
    private func setIcon(badged: Bool) {
        guard let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: AppIdentity.name)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) else { return }
        guard badged else { symbol.isTemplate = true; item?.button?.image = symbol; return }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            let dot: CGFloat = 5
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(AppIdentity.name), update available"
        item?.button?.image = image
    }

    @objc private func toggleLauncher() { toggle() }
    @objc private func toggleVoice() { preferences.voiceEnabled.toggle() }
    @objc private func openUpdate() { if let release = updates.available { Frontmost.open(release.page) } }
    @objc private func openPermission(_ sender: NSMenuItem) {
        guard let permission = sender.representedObject as? Permission else { return }
        permission.openSystemSettings()
    }
}
