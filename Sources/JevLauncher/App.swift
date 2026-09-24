import AppKit
import SwiftUI
import Carbon
import LauncherCore

@main
struct JevLauncherApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") { Diagnostics.run(); return }
        if CommandLine.arguments.contains("--store-jev-key") { Diagnostics.storeJevKey(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose-jev"), CommandLine.arguments.indices.contains(index + 1) {
            Diagnostics.jev(Array(CommandLine.arguments[(index + 1)...])); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose-source"), CommandLine.arguments.indices.contains(index + 1) {
            Diagnostics.source(CommandLine.arguments[index + 1]); return
        }
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

/// Runtime state that Settings shows but does not persist.
@MainActor
final class LauncherStatus: ObservableObject {
    @Published var launcherHotkeyMessage: String?
    @Published var windowHotkeyMessage: String?
    var hotkeyMessage: String? { launcherHotkeyMessage ?? windowHotkeyMessage }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AppCommands {
    private let preferences = Preferences()
    private lazy var updates = UpdateChecker(preferences: preferences)
    private var welcome: WelcomeWindow?
    private let catalogue = AppCatalogue()
    private lazy var model = LauncherModel(preferences: preferences, catalogue: catalogue, jev: JevService(usage: .shared), usage: .shared)
    private let hotkeys = HotkeyCenter()
    private var launcherHotkey: (hotkey: Hotkey, token: UInt32)?
    private var windowHotkeyIDs: [UInt32] = []
    private var windowShortcutsApplied = false
    private var edgeSnappingActive = false
    private let status = LauncherStatus()
    private var panel: LauncherPanel!
    private var settings: SettingsWindow?
    private var statusMenu: StatusMenu?
    private var keyMonitor: Any?
    private var wasVisible = false
    private let backdrop = LauncherBackdrop()
    private var previousApp: NSRunningApplication?
    private let preview = FilePreview()
    private let resultActions = ResultActions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = LauncherPanel()
        let content = LauncherView(model: model, speech: model.speech, catalogue: catalogue,
                                   actions: { [weak self] in self?.showActions() })
        panel.host(content)
        panel.delegate = self
        model.onClose = { [weak self] restore in self?.hide(restoreFocus: restore) }
        model.openLunaSettings = { [weak self] in self?.showSettings(tab: .luna) }
        model.onFailure = { [weak self] text in
            guard let self else { return }
            self.show(); self.model.message = text
        }
        AppMenus.install(commands: self)
        statusMenu = StatusMenu(preferences: preferences, updates: updates, commands: self,
                                isOpen: { [weak self] in self?.wasVisible ?? false }, toggle: { [weak self] in self?.toggle() })
        // Snapshot runs leave global shortcuts to the running copy of the app.
        if UISnapshots.directory == nil { configureHotkeys() }
        Task { await JevKeyCache.shared.load() }
        observeAppSwitches()
        catalogue.refresh(extra: preferences.appFolders)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.wasVisible, event.window === self.panel else { return event }
            // An input method composing text owns Return, arrows, and Escape until it commits.
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            switch event.keyCode {
            case 53:
                self.hide()
                return nil
            case 36, 76: self.model.execute(paste: event.modifierFlags.contains(.shift)); return nil
            case 51:
                // ⌫ stops a port's process once the row is picked; ⌘⌫ stops it at once. Otherwise ⌫ edits the search.
                guard case .stopProcess = self.model.selected?.action,
                      event.modifierFlags.contains(.command) || self.model.manualSelection
                        || self.model.pendingConfirmID == self.model.selectedID else { return event }
                self.model.stopSelectedPort()
                return nil
            case 6 where event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift):
                // ⌘Z undoes a Jev pick. Otherwise the search field keeps its own undo.
                return self.model.undoJevPick() ? nil : event
            case 125: self.model.moveSelection(1); self.preview.update(path: self.model.selected?.path); return nil
            case 126: self.model.moveSelection(-1); self.preview.update(path: self.model.selected?.path); return nil
            case 40 where event.modifierFlags.contains(.command): self.showActions(); return nil
            case 16 where event.modifierFlags.contains(.command): self.togglePreview(); return nil
            case 15 where event.modifierFlags.contains(.command): self.model.revealSelected(); return nil
            case 8 where event.modifierFlags.contains([.command, .shift]): self.model.copyPath(); return nil
            default: return event
            }
        }
        // A menu-bar app stays quiet at login; `--open` shows the panel for diagnostics.
        // A new install shows the welcome window once instead.
        if let directory = UISnapshots.directory { runSnapshots(to: directory); return }
        updates.start()
        if CommandLine.arguments.contains("--open") { show() }
        else if !preferences.welcomeShown || CommandLine.arguments.contains("--welcome") { showWelcome() }
    }
    /// Renders each state in turn. Every capture waits for the previous step, so a
    /// slow step cannot make two captures share one state. Snapshot mode does not
    /// take key focus, activate the app, block clicks, or show windows on screen.
    private func runSnapshots(to directory: String) {
        let demo = DemoData.isEnabled
        let rig = LauncherSnapshotRig(catalogue: catalogue, demo: demo)
        rig.open()
        let model = rig.model
        // Demo Settings and welcome captures use the rig's fresh preferences, not this Mac's.
        let shownPreferences = demo ? model.preferences : preferences
        let shownModel = demo ? model : self.model
        let launcher: () -> NSView? = { rig.panel.hostedView }
        let settingsView: () -> NSView? = { [weak self] in self?.settings?.window?.contentView }
        var steps: [(name: String, wait: Double, view: () -> NSView?, action: () -> Void)] = [
            ("launcher-empty", 1.0, launcher, {}),
            ("launcher-suggestions", 0.6, launcher, { rig.seedSuggestions() }),
            ("launcher-query", 0.8, launcher, { model.updateQuery("saf", typed: true) }),
            ("launcher-calculator", 0.6, launcher, { model.updateQuery("10 km in mi", typed: true) }),
            ("launcher-sum", 0.6, launcher, { model.updateQuery("12 * (8 + 2)", typed: true) }),
            ("launcher-windows", 0.6, launcher, { model.updateQuery("left", typed: true) }),
            ("launcher-files-loading", 0.05, launcher, { model.updateQuery(demo ? "in:downloads" : "kind:pdf in:downloads", typed: true) }),
            ("launcher-files", 2.0, launcher, {}),
            ("launcher-files-empty", 2.0, launcher, { model.updateQuery("find file zzqxv-no-match", typed: true) }),
            ("launcher-clipboard", 0.6, launcher, { rig.seedClipboard(); model.updateQuery("clip", typed: true) }),
            ("launcher-message", 0.6, launcher, {
                model.updateQuery("saf", typed: true)
                model.message = "This app moved or was removed. Refresh apps in Settings › Search › Advanced."
            })
        ]
        steps.append(("", 0, { nil }, { [weak self] in
            guard let self else { return }
            rig.close()
            self.settings = SettingsWindow(preferences: shownPreferences, model: shownModel, catalogue: shownModel.catalogue, status: self.status, updates: self.updates, changed: {})
            self.settings?.window?.alphaValue = 0
            self.settings?.window?.ignoresMouseEvents = true
            self.settings?.window?.orderFrontRegardless()
        }))
        for tab in SettingsWindow.Tab.allCases {
            steps.append(("settings-" + tab.rawValue, 0.9, settingsView, { [weak self] in self?.settings?.select(tab) }))
        }
        steps.append(("welcome", 0.9, { [weak self] in self?.welcome?.window?.contentView }, { [weak self] in
            guard let self else { return }
            self.settings?.window?.orderOut(nil)
            self.welcome = WelcomeWindow(preferences: shownPreferences, model: shownModel, status: self.status, changed: {}, openSettings: {})
            self.welcome?.window?.alphaValue = 0
            self.welcome?.window?.ignoresMouseEvents = true
            self.welcome?.window?.orderFrontRegardless()
        }))
        func run(_ index: Int) {
            guard index < steps.count else { rig.removePreferences(); NSApp.terminate(nil); return }
            let step = steps[index]
            step.action()
            DispatchQueue.main.asyncAfter(deadline: .now() + step.wait) {
                if !step.name.isEmpty, let view = step.view() {
                    UISnapshots.write(view, name: step.name, to: directory)
                    let window = view.window?.frame.size ?? .zero
                    print("[Jev snapshot] \(step.name) window=\(Int(window.width))x\(Int(window.height)) content=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
                    fflush(stdout)
                }
                run(index + 1)
            }
        }
        run(0)
    }
    /// Applies shortcut and snapping preferences. Each part changes only when its preference changed.
    func configureHotkeys() {
        applyLauncherHotkey()
        applyWindowShortcuts()
        model.windows.gap = preferences.gap
        if preferences.edgeSnapping != edgeSnappingActive {
            edgeSnappingActive = preferences.edgeSnapping
            if edgeSnappingActive { model.windows.startEdgeSnapping() } else { model.windows.stopEdgeSnapping() }
        }
    }
    private func applyLauncherHotkey() {
        let outcome = HotkeySwap.apply(requested: preferences.hotkey, active: launcherHotkey, register: { hotkey in
            self.hotkeys.register(key: hotkey.keyCode, modifiers: hotkey.carbonModifiers) { [weak self] in self?.toggle() }
        }, unregister: { self.hotkeys.unregister($0) })
        switch outcome {
        case .unchanged: break
        case let .switched(hotkey, token):
            launcherHotkey = (hotkey, token)
            status.launcherHotkeyMessage = nil
        case let .failed(keep):
            let requested = preferences.hotkey
            if let keep {
                status.launcherHotkeyMessage = "\(requested.title) is in use by another app. \(keep.title) is still active."
                preferences.hotkey = keep
            } else {
                status.launcherHotkeyMessage = "\(requested.title) is in use by another app. Choose another shortcut."
                model.message = status.launcherHotkeyMessage
            }
        }
    }
    private func applyWindowShortcuts() {
        guard preferences.windowShortcuts != windowShortcutsApplied else { return }
        windowShortcutsApplied = preferences.windowShortcuts
        windowHotkeyIDs.forEach(hotkeys.unregister)
        windowHotkeyIDs = []
        status.windowHotkeyMessage = nil
        guard preferences.windowShortcuts else { return }
        let mods = UInt32(controlKey | optionKey | cmdKey)
        let keys: [(Int, WindowAction)] = [
            (kVK_LeftArrow, .leftHalf), (kVK_RightArrow, .rightHalf), (kVK_UpArrow, .topHalf), (kVK_DownArrow, .bottomHalf),
            (kVK_ANSI_U, .topLeftQuarter), (kVK_ANSI_I, .topRightQuarter), (kVK_ANSI_J, .bottomLeftQuarter), (kVK_ANSI_K, .bottomRightQuarter),
            (kVK_ANSI_1, .leftThird), (kVK_ANSI_2, .centerThird), (kVK_ANSI_3, .rightThird),
            (kVK_Return, .maximize), (kVK_ANSI_Z, .restore), (kVK_ANSI_N, .nextDisplay), (kVK_ANSI_P, .previousDisplay)
        ]
        for (key, action) in keys {
            let id = hotkeys.register(key: UInt32(key), modifiers: mods) { [weak self] in
                guard let self else { return }
                if !self.panel.isVisible { self.model.windows.captureTarget() }
                do { try self.model.windows.execute(action, cycle: true) }
                catch { self.show(); self.model.message = error.localizedDescription }
            }
            if let id { windowHotkeyIDs.append(id) } else { status.windowHotkeyMessage = "One or more window shortcuts are in use by another app." }
        }
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
        panel.place(on: NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)
        wasVisible = true
        backdrop.show { [weak self] in self?.hide() }
        // The panel is non-activating: it takes typing without activating the app, so no Space switch.
        panel.makeKeyAndOrderFront(nil)
        model.focusSearch?()
        traceInteraction("opened")
        panel.displayIfNeeded()
        NotificationCenter.default.post(name: .launcherDidOpen, object: nil)
    }
    private func showActions() {
        guard let view = panel.contentView else { return }
        let row = model.selectedRowRect?().map { view.convert($0, from: nil) }
        let anchor = row.map { NSPoint(x: $0.minX + 60, y: $0.minY) } ?? NSPoint(x: view.bounds.width - 195, y: 45)
        resultActions.show(model: model, in: view, at: anchor, preview: { [weak self] in self?.togglePreview() }, dismissed: { [weak self] in self?.hide() })
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
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        print("[Jev interaction] \(event) visible=\(wasVisible) active=\(NSApp.isActive) key=\(panel.isKeyWindow) editing=\(editing) size=\(Int(panel.frame.width))x\(Int(panel.frame.height)) frontmost=\(front) queryLength=\(model.query.count)")
        fflush(stdout)
    }
    /// Command-Tab or a click on another app's window must not leave the launcher floating.
    private func observeAppSwitches() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { if self.wasVisible { self.hide(restoreFocus: false) } }
        }
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
    func applicationDidHide(_ notification: Notification) {
        hide(restoreFocus: false)
    }
    /// Command-W on the launcher runs the normal dismissal instead of a bare window close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel else { return true }
        hide()
        return false
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        // Never leave a stale click catcher after a display is disconnected.
        hide()
    }
    func showSettings(tab: SettingsWindow.Tab) {
        showSettings()
        settings?.select(tab)
    }
    @objc func showSettings() {
        hide(restoreFocus: false)
        if settings == nil {
            settings = SettingsWindow(preferences: preferences, model: model, catalogue: catalogue, status: status, updates: updates,
                                      changed: { [weak self] in self?.configureHotkeys() })
        }
        NSApp.activate()
        settings?.showWindow(nil)
    }
    @objc func showWelcome() {
        hide(restoreFocus: false)
        preferences.welcomeShown = true
        if welcome == nil {
            welcome = WelcomeWindow(preferences: preferences, model: model, status: status,
                                    changed: { [weak self] in self?.configureHotkeys() },
                                    openSettings: { [weak self] in self?.showSettings() })
        }
        NSApp.activate()
        welcome?.showWindow(nil)
    }
    @objc func checkForUpdates() { updates.checkAndReport() }
    @objc func showAbout() { AboutPanel.show() }
    @objc func openWebsite() { NSWorkspace.shared.open(AppIdentity.website) }
    @objc func openSourceCode() { NSWorkspace.shared.open(AppIdentity.repository) }
    @objc func reportIssue() { NSWorkspace.shared.open(AppIdentity.issues) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        backdrop.close(); resultActions.dismiss(); preview.close()
        model.end(); model.windows.stopEdgeSnapping(); hotkeys.clear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
