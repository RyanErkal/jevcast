import AppKit

/// Menu-bar item. The menu is rebuilt each time it opens so the open/hide
/// label, the shortcut hint, voice toggle, and permission ticks stay current.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let preferences: Preferences
    private let isOpen: () -> Bool
    private let toggle: () -> Void
    private let showSettings: () -> Void

    init(preferences: Preferences, isOpen: @escaping () -> Bool, toggle: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.preferences = preferences; self.isOpen = isOpen; self.toggle = toggle; self.showSettings = showSettings
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Jev Launcher")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Jev Launcher"
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        self.item = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = menu.addItem(withTitle: isOpen() ? "Hide Jev Launcher" : "Open Jev Launcher", action: #selector(toggleLauncher), keyEquivalent: preferences.hotkey.keyEquivalent)
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
        let holder = menu.addItem(withTitle: "Permissions", action: nil, keyEquivalent: "")
        holder.submenu = permissions

        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Jev Launcher", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Jev Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleLauncher() { toggle() }
    @objc private func toggleVoice() { preferences.voiceEnabled.toggle() }
    @objc private func openSettings() { showSettings() }
    /// A menu-bar app is not active, so bring it forward or the panel opens behind other apps.
    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func openPermission(_ sender: NSMenuItem) {
        guard let permission = sender.representedObject as? Permission else { return }
        permission.openSystemSettings()
    }
}
