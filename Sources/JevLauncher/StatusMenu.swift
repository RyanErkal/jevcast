import AppKit
import Combine

/// Menu-bar item. The menu is rebuilt each time it opens so the open/hide label,
/// the shortcut hint, the problems that need attention, and the update stay current.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let preferences: Preferences
    private let updates: UpdateChecker
    private let tasks: LunaTaskCenter
    private weak var commands: AppCommands?
    private let isOpen: () -> Bool
    private let toggle: () -> Void
    private let openSettings: (SettingsWindow.Tab) -> Void
    private var subscription: AnyCancellable?

    init(preferences: Preferences, updates: UpdateChecker, commands: AppCommands, tasks: LunaTaskCenter,
         isOpen: @escaping () -> Bool, toggle: @escaping () -> Void, openSettings: @escaping (SettingsWindow.Tab) -> Void) {
        self.preferences = preferences; self.updates = updates; self.commands = commands; self.tasks = tasks
        self.isOpen = isOpen; self.toggle = toggle; self.openSettings = openSettings
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

    /// Something a feature the user turned on needs, and the Settings tab that fixes it.
    private struct Attention { let title: String; let tab: SettingsWindow.Tab }
    private var attention: [Attention] {
        var list: [Attention] = []
        if (preferences.windowShortcuts || preferences.edgeSnapping) && !Permission.accessibility.isGranted {
            list.append(Attention(title: "Allow Accessibility for Windows…", tab: .general))
        }
        if preferences.voiceEnabled && !(Permission.microphone.isGranted && Permission.speech.isGranted) {
            list.append(Attention(title: "Allow Microphone and Speech for Voice…", tab: .voice))
        }
        if preferences.jevEnabled, JevKeyCache.shared.state == .missing {
            list.append(Attention(title: "Add a Jev Key…", tab: .ai))
        }
        return list
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let commands else { return }
        if let release = updates.available {
            menu.addItem(withTitle: "Update to \(release.version)…", action: #selector(openUpdate), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let open = menu.addItem(withTitle: isOpen() ? "Hide \(AppIdentity.name)" : "Open \(AppIdentity.name)", action: #selector(toggleLauncher), keyEquivalent: preferences.hotkey.keyEquivalent)
        open.keyEquivalentModifierMask = preferences.hotkey.menuModifiers
        open.target = self
        menu.addItem(.separator())

        menu.addItem(AppMenus.item("Mail", #selector(AppCommands.openMailWindow), commands))
        menu.addItem(AppMenus.item("Clean Up…", #selector(AppCommands.showCleanup), commands))
        if !tasks.tasks.isEmpty || !tasks.runs.isEmpty {
            let running = tasks.running.count
            menu.addItem(AppMenus.item(running > 0 ? "Luna Tasks (\(running) running)" : "Luna Task Results",
                                       #selector(AppCommands.showTaskResults), commands))
        }
        menu.addItem(.separator())

        for entry in attention {
            let row = menu.addItem(withTitle: entry.title, action: #selector(fix(_:)), keyEquivalent: "")
            row.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Needs attention")
            row.representedObject = entry.tab.rawValue
            row.target = self
        }
        menu.addItem(AppMenus.item("Settings…", #selector(AppCommands.showSettings), commands, key: ","))
        let help = AppMenus.helpMenu(commands: commands)
        if updates.available == nil {
            help.addItem(.separator())
            help.addItem(AppMenus.item("Check for Updates…", #selector(AppCommands.checkForUpdates), commands))
        }
        menu.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = help
        menu.addItem(AppMenus.item("About \(AppIdentity.name)", #selector(AppCommands.showAbout), commands))
        menu.addItem(.separator())
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
    @objc private func openUpdate() { if let release = updates.available { Frontmost.open(release.page) } }
    @objc private func fix(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = SettingsWindow.Tab(rawValue: raw) else { return }
        if tab == .ai { UserDefaults.standard.set(AISettings.Part.jev.rawValue, forKey: "settingsAIPart") }
        openSettings(tab)
    }
}
