import AppKit
import Combine
import UserNotifications
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
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose-mail-actions"), CommandLine.arguments.indices.contains(index + 1) {
            Diagnostics.mailActions(to: CommandLine.arguments[index + 1]); return
        }
        if CommandLine.arguments.contains("--hyper-led-test") { HyperKeyController.runLightTest(); return }
        if CommandLine.arguments.contains("--diagnose-mail") { Diagnostics.mail(); return }
        if CommandLine.arguments.contains("--cleanup") { Diagnostics.cleanup(apply: CommandLine.arguments.contains("--apply")); return }
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AppCommands, UNUserNotificationCenterDelegate {
    private let preferences = Preferences()
    private lazy var updates = UpdateChecker(preferences: preferences)
    private var welcome: WelcomeWindow?
    private let catalogue = AppCatalogue()
    /// Snapshot runs keep clipboard history in memory, so they never read or change the stored history.
    private lazy var model = LauncherModel(preferences: preferences, catalogue: catalogue, jev: JevService(usage: .shared),
                                           clipboard: ClipboardHistory(folder: UISnapshots.directory == nil ? ClipboardStore.defaultFolder : nil),
                                           usage: .shared)
    private lazy var dictation = DictationController(preferences: preferences, model: model)
    private let hotkeys = HotkeyCenter()
    private lazy var hyper = HyperKeyController(preferences: preferences)
    private var launcherHotkey: (hotkey: Hotkey, token: UInt32)?
    private var windowHotkeyIDs: [UInt32] = []
    private var windowShortcutsApplied = false
    private var edgeSnappingActive = false
    private let status = LauncherStatus()
    private var panel: LauncherPanel!
    private var settings: SettingsWindow?
    private var mail: MailWindow?
    /// One mail model for the Mail view and the mail window, so ⌘O keeps your place.
    private lazy var mailModel = MailModel(quill: { [unowned self] in try await self.model.sendQuill($0) },
                                           quillAllowed: { [unowned self] in self.model.allowedQuillContext.contains(.mailMessage) })
    private var viewSizeWatch: AnyCancellable?
    private var resultWindow: QuillResultWindow?
    private var statusMenu: StatusMenu?
    private var keyMonitor: Any?
    private var wasVisible = false
    private let backdrop = LauncherBackdrop()
    private var previousApp: NSRunningApplication?
    private let preview = FilePreview()
    private let resultActions = ResultActions()
    /// Background automations. Snapshot runs use a throwaway store and never touch the real folder.
    private lazy var automations: AutomationCenter = {
        guard UISnapshots.directory != nil else { return AutomationCenter() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-snapshot-automations-\(getpid())", isDirectory: true)
        return AutomationCenter(isolatedStore: AutomationStore(root: root))
    }()
    private var automationsWindow: AutomationsWindow?
    /// Holds demo Automations views on screen for `--snapshot-ui --demo`.
    private var automationSnapshotWindow: NSWindow?
    /// `--automation-alerts`: the runner opened the app to show alerts. No welcome, no launcher.
    private let alertLaunch = CommandLine.arguments.contains("--automation-alerts")
    private let notchDemo = CommandLine.arguments.contains("--notch-demo")

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = LauncherPanel()
        let content = LauncherView(model: model, speech: model.speech, catalogue: catalogue,
                                   actions: { [weak self] in self?.showActions() })
        panel.host(content)
        panel.delegate = self
        model.clipboardPasteTarget = { [weak self] in self?.previousApp?.processIdentifier }
        model.onClose = { [weak self] restore in self?.hide(restoreFocus: restore) }
        model.openQuillSettings = { [weak self] in self?.showSettings(tab: .ai, aiPart: .quill) }
        model.openSettingsTab = { [weak self] name in
            if let tab = SettingsWindow.Tab(rawValue: name) { self?.showSettings(tab: tab) }
        }
        model.openMail = { [weak self] rowID in self?.showMailView(select: rowID) }
        model.openTaskRun = { [weak self] run in self?.showRunView(run) }
        model.openView = { [weak self] id in if let view = ViewID(rawValue: id) { self?.showView(view) } }
        model.makePage = { [weak self] id in
            guard let self else { return nil }
            // The view and the mail window share one inbox; an open window comes forward instead.
            if id == .mail, self.mail?.isOpen == true { self.showMail(); return nil }
            return LauncherPages.make(id, model: self.model, links: self.pageLinks, snapshot: false)
        }
        viewSizeWatch = model.$page.map { $0 != nil }.removeDuplicates().sink { [weak self] wide in self?.panel.setViewSize(wide) }
        UNUserNotificationCenter.current().delegate = self
        configureAutomations()
        // Snapshot runs never run tasks.
        if UISnapshots.directory == nil { model.quillTasks.start() }
        model.composeMail = { [weak self] address in self?.showMail(compose: address) }
        model.onFailure = { [weak self] text in
            guard let self else { return }
            self.show(); self.model.message = text
        }
        AppMenus.install(commands: self)
        statusMenu = StatusMenu(preferences: preferences, updates: updates, commands: self, tasks: model.quillTasks, automations: automations,
                                isOpen: { [weak self] in self?.wasVisible ?? false }, toggle: { [weak self] in self?.toggle() },
                                openSettings: { [weak self] tab in self?.showSettings(tab: tab) })
        // Snapshot runs leave global shortcuts to the running copy of the app.
        if UISnapshots.directory == nil, !notchDemo {
            configureHotkeys()
            dictation.canStart = { [weak self] in !(self?.wasVisible ?? false) }
            dictation.start()
            hyper.perform = { [weak self] action, flags in self?.performHyper(action, flags: flags) }
            hyper.launch()
        }
        Task { await JevKeyCache.shared.load() }
        observeAppSwitches()
        catalogue.refresh(extra: preferences.appFolders)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.wasVisible, event.window === self.panel else { return event }
            // An input method composing text owns Return, arrows, and Escape until it commits.
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            // A view such as Mail takes ↑↓, Return, ⌫, Escape, and ⌘O; other keys type in the filter.
            if self.model.page != nil { return self.model.handleViewKey(event) ? nil : event }
            // With Quill's answer showing, Escape goes back to the rows and row keys do nothing.
            if self.model.quillAnswer != nil {
                switch event.keyCode {
                case 53: self.model.dismissQuill(); return nil
                case 36, 76: self.model.execute(paste: event.modifierFlags.contains(.shift)); return nil
                case 125, 126, 51: return event.keyCode == 51 ? event : nil
                default: if event.modifierFlags.contains(.command) { return event.charactersIgnoringModifiers == "c" ? event : nil }
                }
            }
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
            case 48 where event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]):
                // Tab completes a "/" or "$" row's name.
                return self.model.completePrefix() ? nil : event
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
        if notchDemo { runNotchDemo(); return }
        if let flag = CommandLine.arguments.firstIndex(of: "--capture-automations"), flag + 1 < CommandLine.arguments.count {
            AutomationsWindowCapture.run(to: CommandLine.arguments[flag + 1]); return
        }
        automations.start()
        if CommandLine.arguments.contains("--turn-on-runner") { automations.turnOnRunner() }
        updates.start()
        // The runner opened the app for an alert: AutomationCenter shows it; nothing else opens.
        if alertLaunch { return }
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
        // Views in the panel. Mail, Calendar, and Clean Up render empty: snapshots never read them.
        steps += ViewID.allCases.map { id in ("view-" + id.rawValue, 1.0, launcher, { model.closeAllViews(); model.showView(id) }) }
        for (name, id) in [("view-clipboard-image", DemoClipboard.imageID), ("view-clipboard-code", DemoClipboard.codeID)] {
            steps.append((name, 1.2, launcher, {
                model.closeAllViews(); model.showView(.clipboard); (model.page as? ClipboardPage)?.select(id)
            }))
        }
        steps.append(("view-calendar-week", 1.0, launcher, {
            model.closeAllViews(); model.showView(.calendar); (model.page as? CalendarPage)?.setMode(.week)
        }))
        steps.append(("", 0, { nil }, { [weak self] in
            guard let self else { return }
            rig.close()
            self.settings = SettingsWindow(preferences: shownPreferences, model: shownModel, catalogue: shownModel.catalogue, status: self.status, updates: self.updates,
                                           dictation: DictationController(preferences: shownPreferences, model: shownModel),
                                           automations: self.automations,
                                           hyper: HyperKeyController(preferences: shownPreferences), changed: {}, openMail: {})
            self.settings?.window?.alphaValue = 0
            self.settings?.window?.ignoresMouseEvents = true
            self.settings?.window?.orderFrontRegardless()
        }))
        // Panes with parts render each part. The stored choice is put back after the last capture.
        let partKeys = ["settingsGeneralPart", "settingsAIPart", "settingsLibraryPart", "settingsAutomationsPart", "settingsWindowsPart"]
        let storedParts = partKeys.map { UserDefaults.standard.string(forKey: $0) }
        for tab in SettingsWindow.Tab.allCases {
            let parts: (key: String, values: [String])? = switch tab {
            case .general: ("settingsGeneralPart", GeneralSettings.Part.allCases.map(\.rawValue))
            case .ai: ("settingsAIPart", AISettings.Part.allCases.map(\.rawValue))
            case .library: ("settingsLibraryPart", CommandSettings.Part.allCases.map(\.rawValue))
            case .automations: ("settingsAutomationsPart", AutomationSettingsPane.Part.allCases.map(\.rawValue))
            case .windows: ("settingsWindowsPart", WindowSettings.Part.allCases.map(\.rawValue))
            default: nil
            }
            guard let parts else {
                steps.append(("settings-" + tab.rawValue, 0.9, settingsView, { [weak self] in self?.settings?.select(tab) }))
                continue
            }
            for value in parts.values {
                let slug = value.lowercased().replacingOccurrences(of: " & ", with: "-")
                steps.append(("settings-\(tab.rawValue)-\(slug)", 0.9, settingsView, { [weak self] in
                    UserDefaults.standard.set(value, forKey: parts.key)
                    self?.settings?.select(tab)
                }))
            }
        }
        // Automations screens, demo only: they show invented runs and files, never this Mac's.
        if demo {
            let shots: [(String, AnyView, NSSize)] = [
                ("automations-approval", AnyView(AutomationsWindow.snapshotApproval()), NSSize(width: 760, height: 640)),
                ("automations-editor", AnyView(AutomationsWindow.snapshotEditor(.metricsRefresh).frame(width: 720, height: 820)), NSSize(width: 720, height: 820))
            ]
            for (name, view, size) in shots {
                steps.append((name, 1.2, { [weak self] in self?.automationSnapshotWindow?.contentView }, { [weak self] in
                    guard let self else { return }
                    self.settings?.window?.orderOut(nil)
                    self.automationSnapshotWindow?.orderOut(nil)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = NSHostingView(rootView: view)
                    window.alphaValue = 0
                    window.ignoresMouseEvents = true
                    window.orderFrontRegardless()
                    self.automationSnapshotWindow = window
                }))
            }
        }
        for page in WelcomePage.allCases {
            steps.append(("welcome-" + page.rawValue, 0.9, { [weak self] in self?.welcome?.window?.contentView }, { [weak self] in
                guard let self else { return }
                for (key, value) in zip(partKeys, storedParts) { UserDefaults.standard.set(value, forKey: key) }
                self.settings?.window?.orderOut(nil)
                self.automationSnapshotWindow?.orderOut(nil)
                self.welcome?.close()
                self.welcome = WelcomeWindow(preferences: shownPreferences, model: shownModel, status: self.status, page: page,
                                             changed: {}, openSettings: { _ in }, tryQuery: { _ in })
                self.welcome?.window?.alphaValue = 0
                self.welcome?.window?.ignoresMouseEvents = true
                self.welcome?.window?.orderFrontRegardless()
            }))
        }
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
            let id = hotkeys.register(key: UInt32(key), modifiers: mods) { [weak self] in self?.performWindowAction(action) }
            if let id { windowHotkeyIDs.append(id) } else { status.windowHotkeyMessage = "One or more window shortcuts are in use by another app." }
        }
    }
    /// The window shortcut path, shared by ⌃⌥⌘ shortcuts and the Hyper key.
    private func performWindowAction(_ action: WindowAction) {
        if !panel.isVisible { model.windows.captureTarget() }
        do { try model.windows.execute(action, cycle: true) }
        catch { show(); model.message = error.localizedDescription }
    }
    /// Runs a Hyper key action. Built-in IDs are checked against the fixed list; nothing else runs.
    private func performHyper(_ action: HyperAction, flags: CGEventFlags) {
        switch action {
        case .builtIn(let id):
            guard let item = HyperBuiltIn(rawValue: id) else { return }
            if let window = item.windowAction { performWindowAction(window); return }
            switch item {
            case .launcher: show()
            case .mail: showView(.mail)
            case .calendar: showView(.calendar)
            case .automations: showAutomations()
            case .clipboard: showView(.clipboard)
            default: break
            }
        case .openApp(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                show(); model.message = "The app for this Hyper key was not found."; return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .sendKey(let code):
            HyperKeyTap.post(keyCode: code, flags: flags)
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
        preview.close(); panel.orderOut(nil); model.end(); model.closeAllViews(); backdrop.close()
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
    // MARK: Automations

    /// Connects the automation center to preferences, windows, and the notch panel. Snapshot runs leave it isolated.
    private func configureAutomations() {
        model.automationCenter = automations
        automations.alertSettings = { [weak self] in self?.preferences.automationAlertSettings ?? AlertSettings() }
        automations.alertSeconds = { [weak self] in self?.preferences.automationAlertSeconds ?? 6 }
        automations.openWindow = { [weak self] automationID, runID in self?.showAutomations(automationID: automationID, runID: runID) }
        automations.openSettings = { [weak self] in self?.showSettings(tab: .automations) }
        NotchAlertController.shared.onAction = { [weak self] id, action in
            guard let self, !self.automations.handleAlertAction(id, action) else { return }
            guard id.hasPrefix("quill:"), action == "open" else { return }
            let runID = String(id.dropFirst("quill:".count))
            if let run = self.model.quillTasks.runs.first(where: { $0.id == runID }) { self.showRun(run) }
        }
        // Quill task failures use the notch panel; successes stay silent in the history.
        model.quillTasks.onFailure = { [weak self] run in
            guard let self, self.preferences.automationAlerts, UISnapshots.directory == nil else { return }
            let hide = self.preferences.automationHideNames
            NotchAlertController.shared.visibleSeconds = self.preferences.automationAlertSeconds
            NotchAlertController.shared.show(NotchAlert(id: "quill:" + run.id, symbol: "sparkles",
                                                        title: hide ? "A Quill task" : run.taskName,
                                                        message: hide ? "It did not finish." : run.preview, tone: .failure,
                                                        actions: [.init("Open", id: "open", primary: true), .init("Later", id: "later")]))
        }
    }

    /// The Automations window, made on first use.
    func showAutomations(automationID: String? = nil, runID: String? = nil) {
        hide(restoreFocus: false)
        if automationsWindow == nil {
            let window = AutomationsWindow(center: automations, quill: model.quillTasks)
            window.model.configureNewDraft = { [weak self] draft in
                guard let self else { return }
                draft.applyDefaults(self.preferences)
            }
            // Quill tasks are made by typing a schedule in the launcher, so open it with an example to edit.
            window.onNewQuillTask = { [weak self] in
                self?.show()
                self?.model.query = "every morning at 8 brief me on my meetings"
            }
            automationsWindow = window
        }
        automationsWindow?.show(automationID: automationID, runID: runID)
    }

    @objc func showAutomationsWindow() { showAutomations() }

    /// `--notch-demo`: two invented alerts, then quit after 20 seconds.
    private func runNotchDemo() {
        NotchAlertController.shared.onAction = { id, action in print("[Jev notch] \(id) \(action)"); fflush(stdout) }
        NotchAlertController.shared.show(NotchAlert(id: "demo-approval", symbol: "folder.badge.gearshape", title: "Desktop tidy",
                                                    message: "12 files to move. Review before anything changes.", tone: .attention,
                                                    actions: [.init("Review", id: "review", primary: true), .init("Later", id: "later")]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            NotchAlertController.shared.show(NotchAlert(id: "demo-failure", symbol: "chart.bar.xaxis", title: "Sample metrics refresh",
                                                        message: "Failed: the sample source did not answer.", tone: .failure,
                                                        actions: [.init("Retry", id: "retry", primary: true), .init("Open", id: "open")]))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
    }

    /// A scheduled task's result.
    func showRun(_ run: QuillTaskRun) {
        hide(restoreFocus: false)
        resultWindow = QuillResultWindow(run: run)
        resultWindow?.show()
    }
    /// Shows task results while Jevcast is in front too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
    /// A click on a task's notification opens its result.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo[QuillStorageKeys.notificationRunKey] as? String else { return }
        await MainActor.run {
            if let run = self.model.quillTasks.runs.first(where: { $0.id == id }) { self.showRun(run) }
        }
    }
    /// The Jevcast mail window, made on first use.
    func showMail(select rowID: Int64? = nil, compose address: String? = nil) {
        hide(restoreFocus: false)
        if mail == nil { mail = MailWindow(model: mailModel) }
        mail?.show(select: rowID, compose: address)
    }
    /// Shows the launcher as a view, such as Mail, in place of a separate window.
    func showView(_ view: ViewID) {
        if view == .mail, mail?.isOpen == true { showMail(); return }
        show(); model.showView(view)
    }
    private func showMailView(select rowID: Int64?) {
        if mail?.isOpen == true { showMail(select: rowID); return }
        showView(.mail)
        if let rowID { (model.page as? MailPage)?.show(rowID) }
    }
    private func showRunView(_ run: QuillTaskRun) {
        showView(.tasks)
        (model.page as? SourcePage)?.showDetail(QuillStorageKeys.runRowPrefix + run.id)
    }
    /// What views open outside the panel. ⌘O on Mail keeps the list's selection in the mail window.
    private var pageLinks: LauncherPages.Links {
        .init(mail: { [unowned self] in self.mailModel },
              mailWindow: { [weak self] rowID in self?.model.closeAllViews(handingOff: true); self?.showMail(select: rowID) },
              runWindow: { [weak self] run in self?.showRun(run) })
    }
    func showSettings(tab: SettingsWindow.Tab, aiPart: AISettings.Part? = nil) {
        if let aiPart { UserDefaults.standard.set(aiPart.rawValue, forKey: "settingsAIPart") }
        showSettings()
        settings?.select(tab)
    }
    @objc func showSettings() {
        hide(restoreFocus: false)
        if settings == nil {
            settings = SettingsWindow(preferences: preferences, model: model, catalogue: catalogue, status: status, updates: updates,
                                      dictation: dictation, automations: automations, hyper: hyper,
                                      changed: { [weak self] in self?.configureHotkeys() },
                                      openMail: { [weak self] in self?.showMail() })
        }
        settings?.showWindow(nil)
        if let window = settings?.window { Frontmost.show(window) }
    }
    @objc func showWelcome() {
        hide(restoreFocus: false)
        preferences.welcomeShown = true
        // A new window each time, so Help › Welcome Guide starts at the first step.
        welcome?.close()
        welcome = WelcomeWindow(preferences: preferences, model: model, status: status,
                                changed: { [weak self] in self?.configureHotkeys() },
                                openSettings: { [weak self] tab in self?.showSettings(tab: tab) },
                                tryQuery: { [weak self] text in self?.tryQuery(text) })
        NSApp.activate()
        welcome?.showWindow(nil)
    }
    /// Opens the launcher with a welcome-guide example typed in.
    private func tryQuery(_ text: String) {
        show()
        // Typed, so a voice transcript does not replace the example.
        model.updateQuery(text, typed: true)
    }
    @objc func checkForUpdates() { updates.checkAndReport() }
    @objc func openMailWindow() { showView(.mail) }
    @objc func showCleanup() { showView(.cleanup) }
    @objc func showTaskResults() { showView(.tasks) }
    @objc func showAbout() { AboutPanel.show() }
    @objc func openWebsite() { Frontmost.open(AppIdentity.website) }
    @objc func openSourceCode() { Frontmost.open(AppIdentity.repository) }
    @objc func reportIssue() { Frontmost.open(AppIdentity.issues) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Jevcast opening itself to bring a window forward is not a request for the launcher.
        if Frontmost.selfActivating { return false }
        show(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.clipboard.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        backdrop.close(); resultActions.dismiss(); preview.close()
        model.end(); model.windows.stopEdgeSnapping(); hotkeys.clear()
        if UISnapshots.directory == nil { hyper.shutdown() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
