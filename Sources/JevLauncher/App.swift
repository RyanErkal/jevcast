import AppKit
import SwiftUI
import Carbon
import LauncherCore

@main
struct JevLauncherApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") { Diagnostics.run(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private let catalogue = AppCatalogue()
    private lazy var model = LauncherModel(preferences: preferences, catalogue: catalogue)
    private let hotkeys = GlobalHotkeys()
    private var panel: LauncherPanel!
    private var settingsWindow: NSWindow?
    private var menuItem: NSStatusItem?
    private var keyMonitor: Any?
    private var wasVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = LauncherView(model: model, speech: model.speech, catalogue: catalogue, settings: { [weak self] in self?.showSettings() })
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 548), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Jev Launcher"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: content)
        panel.delegate = self
        model.onClose = { [weak self] in self?.hide() }
        configureMenu()
        configureHotkeys()
        catalogue.refresh(extra: preferences.appFolders)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            switch event.keyCode {
            case 53: self.hide(); return nil
            case 36, 76: self.model.execute(); return nil
            case 125: self.model.moveSelection(1); return nil
            case 126: self.model.moveSelection(-1); return nil
            case 43 where event.modifierFlags.contains(.command): self.showSettings(); return nil
            case 15 where event.modifierFlags.contains(.command): self.model.revealSelected(); return nil
            case 8 where event.modifierFlags.contains([.command, .shift]): self.model.copyPath(); return nil
            default: return event
            }
        }
        show()
    }
    private func configureMenu() {
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem?.button?.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "Jev Launcher")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Jev Launcher", action: #selector(toggle), keyEquivalent: ""); open.target = self; menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Jev Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(quit)
        menuItem?.menu = menu
    }
    private func configureHotkeys() {
        hotkeys.clear()
        let modifier: UInt32 = preferences.hotkey == 1 ? UInt32(optionKey) : preferences.hotkey == 2 ? UInt32(cmdKey) : UInt32(controlKey | shiftKey)
        if !hotkeys.register(key: UInt32(kVK_Space), modifiers: modifier, callback: { [weak self] in self?.toggle() }) {
            model.message = "That shortcut is in use. Choose another in Settings."
        }
        if preferences.windowShortcuts {
            let mods = UInt32(controlKey | optionKey | cmdKey)
            let keys: [(Int, WindowAction)] = [
                (kVK_LeftArrow, .leftHalf), (kVK_RightArrow, .rightHalf), (kVK_UpArrow, .topHalf), (kVK_DownArrow, .bottomHalf),
                (kVK_ANSI_U, .topLeftQuarter), (kVK_ANSI_I, .topRightQuarter), (kVK_ANSI_J, .bottomLeftQuarter), (kVK_ANSI_K, .bottomRightQuarter),
                (kVK_ANSI_1, .leftThird), (kVK_ANSI_2, .centerThird), (kVK_ANSI_3, .rightThird),
                (kVK_Return, .maximize), (kVK_ANSI_Z, .restore), (kVK_ANSI_N, .nextDisplay), (kVK_ANSI_P, .previousDisplay)
            ]
            for (key, action) in keys {
                if !hotkeys.register(key: UInt32(key), modifiers: mods, callback: { [weak self] in
                    guard let self else { return }
                    if !self.panel.isVisible { self.model.windows.captureTarget() }
                    do { try self.model.windows.execute(action, cycle: true) }
                    catch { self.show(); self.model.message = error.localizedDescription }
                }) { model.message = "One or more window shortcuts are in use." }
            }
        }
        model.windows.gap = preferences.gap
        if preferences.edgeSnapping { model.windows.startEdgeSnapping() } else { model.windows.stopEdgeSnapping() }
    }
    @objc private func toggle() { if panel.isVisible { hide() } else { show() } }
    private func show() {
        guard !panel.isVisible else { return }
        model.begin()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - max(40, frame.height * 0.12)))
        }
        wasVisible = true
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .launcherDidOpen, object: nil)
    }
    private func hide() { model.end(); wasVisible = false; panel.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel, wasVisible { hide() }
    }
    @objc private func showSettings() {
        hide()
        if settingsWindow == nil {
            let content = SettingsView(preferences: preferences, model: model, speech: model.speech, catalogue: catalogue, changed: { [weak self] in self?.configureHotkeys() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Jev Launcher Settings"; window.contentView = NSHostingView(rootView: content)
            window.isReleasedWhenClosed = false; window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model.end(); model.windows.stopEdgeSnapping(); hotkeys.clear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
