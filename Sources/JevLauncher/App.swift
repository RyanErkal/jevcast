import AppKit
import SwiftUI
import Carbon
import LauncherCore

@main
struct JevLauncherApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") { Diagnostics.run(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose-files"), CommandLine.arguments.indices.contains(index + 1) {
            Diagnostics.searchFiles(CommandLine.arguments[index + 1]); return
        }
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
    private let backdrop = LauncherBackdrop()
    private var previousApp: NSRunningApplication?
    private let preview = FilePreview()
    private let resultActions = ResultActions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = LauncherView(model: model, speech: model.speech, catalogue: catalogue, settings: { [weak self] in self?.showSettings() }, actions: { [weak self] in self?.showActions() })
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 548), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Jev Launcher"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: content)
        panel.delegate = self
        model.onClose = { [weak self] restore in self?.hide(restoreFocus: restore) }
        configureMenu()
        configureHotkeys()
        catalogue.refresh(extra: preferences.appFolders)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.wasVisible else { return event }
            switch event.keyCode {
            case 53:
                self.hide()
                return nil
            case 36, 76: self.model.execute(); return nil
            case 125: self.model.moveSelection(1); self.preview.update(path: self.model.selected?.path); return nil
            case 126: self.model.moveSelection(-1); self.preview.update(path: self.model.selected?.path); return nil
            case 40 where event.modifierFlags.contains(.command): self.showActions(); return nil
            case 16 where event.modifierFlags.contains(.command): self.togglePreview(); return nil
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
        let trace = PerformanceTrace.start("PanelOpen")
        defer { PerformanceTrace.end("PanelOpen", trace) }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == getpid() ? nil : frontmost
        model.begin()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - max(40, frame.height * 0.12)))
        }
        wasVisible = true
        backdrop.show { [weak self] in self?.hide() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.focusSearch?()
        traceInteraction("opened")
        panel.displayIfNeeded()
        NotificationCenter.default.post(name: .launcherDidOpen, object: nil)
    }
    private func showActions() {
        guard let view = panel.contentView else { return }
        resultActions.show(model: model, in: view, preview: { [weak self] in self?.togglePreview() }, dismissed: { [weak self] in self?.hide() })
    }
    private func togglePreview() {
        model.pauseListening()
        preview.toggle(path: model.selected?.path, beside: panel)
    }
    private func hide(restoreFocus: Bool = true) {
        guard wasVisible else { return }
        wasVisible = false
        resultActions.dismiss()
        preview.close(); model.end(); panel.orderOut(nil); backdrop.close()
        let previous = previousApp
        previousApp = nil
        traceInteraction("closed")
        if restoreFocus, NSApp.isActive, let previous, !previous.isTerminated {
            previous.activate(options: [])
        }
    }
    private func traceInteraction(_ event: String) {
        guard CommandLine.arguments.contains("--trace-interaction") else { return }
        let editing = panel.firstResponder is NSTextView
        print("[Jev interaction] \(event) visible=\(wasVisible) active=\(NSApp.isActive) key=\(panel.isKeyWindow) editing=\(editing)")
        fflush(stdout)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard wasVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        model.focusSearch?()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel, wasVisible { model.focusSearch?(); traceInteraction("focused") }
    }
    func applicationDidResignActive(_ notification: Notification) {
        hide(restoreFocus: false)
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        // Never leave a stale click catcher after a display is disconnected.
        hide()
    }
    @objc private func showSettings() {
        hide(restoreFocus: false)
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
        backdrop.close(); resultActions.dismiss(); preview.close()
        model.end(); model.windows.stopEdgeSnapping(); hotkeys.clear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
