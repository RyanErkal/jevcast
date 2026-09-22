import AppKit

/// Standard main menu so Command shortcuts (⌘, ⌘Q ⌘W and text editing) work
/// in every window, including Settings, without a local key monitor.
@MainActor
enum AppMenus {
    static func install(target: AnyObject, showSettings: Selector) {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Jev Launcher")
        appMenu.addItem(withTitle: "About Jev Launcher", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = appMenu.addItem(withTitle: "Settings…", action: showSettings, keyEquivalent: ",")
        prefs.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Jev Launcher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Jev Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

        NSApp.mainMenu = main
    }
    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(); item.submenu = menu; return item
    }
}
