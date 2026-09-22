import AppKit
import ApplicationServices

/// A menu item in the app that was in front when the launcher opened, such as Safari's
/// "File › New Private Window". Pressing it uses Accessibility, like a click on the menu.
struct MenuCommand: Identifiable, @unchecked Sendable {
    let id: String
    let title: String
    /// "Safari › File", shown beside the title.
    let path: String
    let shortcut: String
    let element: AXUIElement
}

enum MenuScanner {
    static let limit = 400
    /// Menus whose items name the user's documents or windows.
    static let skippedMenus: Set<String> = ["Window", "Open Recent", "Recent Items", "Recent Files", "History", "Bookmarks"]

    /// Reads the enabled menu items of `pid` off the main thread. Empty without Accessibility access.
    static func scan(pid: pid_t, appName: String) async -> [MenuCommand] {
        guard AXIsProcessTrusted() else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
            var found: [MenuCommand] = []
            // Skip the Apple menu. Its items act on the whole Mac, not this app.
            for (index, top) in children(bar).enumerated() where index > 0 {
                let topTitle = string(top, kAXTitleAttribute) ?? ""
                // The Window menu lists document titles. They stay off the list, like file paths.
                guard !topTitle.isEmpty, !skippedMenus.contains(topTitle) else { continue }
                walk(top, path: appName + " › " + topTitle, depth: 0, into: &found)
                if found.count >= limit { break }
            }
            return found
        }.value
    }

    /// Presses the item. Returns false when the app refused it or quit.
    @discardableResult
    static func press(_ command: MenuCommand) -> Bool {
        AXUIElementPerformAction(command.element, kAXPressAction as CFString) == .success
    }

    private static func walk(_ node: AXUIElement, path: String, depth: Int, into found: inout [MenuCommand]) {
        guard depth < 4, found.count < limit else { return }
        for child in children(node) {
            let role = string(child, kAXRoleAttribute)
            if role == kAXMenuRole { walk(child, path: path, depth: depth + 1, into: &found); continue }
            guard role == kAXMenuItemRole, let title = string(child, kAXTitleAttribute), !title.isEmpty else { continue }
            let submenu = children(child).first { string($0, kAXRoleAttribute) == kAXMenuRole }
            if let submenu {
                guard !skippedMenus.contains(title) else { continue }
                walk(submenu, path: path + " › " + title, depth: depth + 1, into: &found)
                continue
            }
            guard bool(child, kAXEnabledAttribute), !title.contains("/") else { continue }
            found.append(MenuCommand(id: "menu:" + path + " › " + title, title: title, path: path,
                                     shortcut: shortcut(child), element: child))
        }
    }

    private static func shortcut(_ item: AXUIElement) -> String {
        guard let key = string(item, kAXMenuItemCmdCharAttribute), !key.isEmpty else { return "" }
        var modifiers = 0
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success, let number = value as? Int {
            modifiers = number
        }
        // Accessibility modifier bits: 1 Shift, 2 Option, 4 Control, 8 means no Command.
        var text = ""
        if modifiers & 4 != 0 { text += "⌃" }
        if modifiers & 2 != 0 { text += "⌥" }
        if modifiers & 1 != 0 { text += "⇧" }
        if modifiers & 8 == 0 { text += "⌘" }
        return text + key
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

/// The user's Apple Shortcuts, read with `shortcuts list` and refreshed at most once a minute.
@MainActor
final class ShortcutsCatalogue {
    static let shared = ShortcutsCatalogue()
    private(set) var names: [String] = []
    private var loadedAt: Date?
    private var loading = false

    func refreshIfStale(now: Date = Date(), then done: @escaping () -> Void = {}) {
        guard !loading, loadedAt.map({ now.timeIntervalSince($0) > 60 }) ?? true else { return }
        loading = true
        Task { [weak self] in
            let names = await CommandRunner.shortcutNames()
            guard let self else { return }
            self.names = names; self.loadedAt = Date(); self.loading = false
            done()
        }
    }
}
