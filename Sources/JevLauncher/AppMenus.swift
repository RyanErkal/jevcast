import AppKit

/// Commands that both the main menu and the menu-bar menu offer.
@MainActor @objc protocol AppCommands: AnyObject {
    func showSettings()
    func showWelcome()
    func checkForUpdates()
    func showAbout()
    func openWebsite()
    func openSourceCode()
    func reportIssue()
    func openMailWindow()
    func showCleanup()
    func showTaskResults()
    func showAutomationsWindow()
}

/// Standard main menu so Command shortcuts (⌘, ⌘Q ⌘W and text editing) work
/// in every window, including Settings, without a local key monitor.
@MainActor
enum AppMenus {
    static func install(commands: AppCommands) {
        let main = NSMenu()

        let appMenu = NSMenu(title: AppIdentity.name)
        appMenu.addItem(item("About \(AppIdentity.name)", #selector(AppCommands.showAbout), commands))
        appMenu.addItem(item("Check for Updates…", #selector(AppCommands.checkForUpdates), commands))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(AppCommands.showSettings), commands, key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppIdentity.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        let help = helpMenu(commands: commands)
        main.addItem(submenu(help))
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
    /// Welcome guide and project links, shared with the menu-bar menu.
    static func helpMenu(commands: AppCommands) -> NSMenu {
        let help = NSMenu(title: "Help")
        help.addItem(item("Welcome Guide", #selector(AppCommands.showWelcome), commands))
        help.addItem(.separator())
        help.addItem(item("\(AppIdentity.name) Website", #selector(AppCommands.openWebsite), commands))
        help.addItem(item("Source Code on GitHub", #selector(AppCommands.openSourceCode), commands))
        help.addItem(item("Report an Issue", #selector(AppCommands.reportIssue), commands))
        return help
    }
    static func item(_ title: String, _ action: Selector, _ target: AnyObject, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(); item.submenu = menu; return item
    }
}
