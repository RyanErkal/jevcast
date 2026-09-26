import AppKit
import SwiftUI

/// The Automations window: background automations, runs that need you, Quill tasks, Codex, and clients.
@MainActor
final class AutomationsWindow: NSWindowController, NSWindowDelegate {
    let center: AutomationCenter
    let quill: QuillTaskCenter
    let model: AutomationsViewModel

    /// Opens Quill's new-task flow. Set by the app.
    var onNewQuillTask: (() -> Void)? {
        get { model.onNewQuillTask }
        set { model.onNewQuillTask = newValue }
    }

    init(center: AutomationCenter, quill: QuillTaskCenter) {
        self.center = center; self.quill = quill
        model = AutomationsViewModel(center: center, quill: quill)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Automations"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 520)
        window.setFrameAutosaveName("JevcastAutomations")
        let hosting = NSHostingController(rootView: AutomationsRootView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        if !window.setFrameUsingName("JevcastAutomations") {
            window.setContentSize(NSSize(width: 1240, height: 780))
            window.center()
        }
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Opens the window, optionally on one automation or run.
    func show(automationID: String?, runID: String?) {
        center.start()
        model.open(automationID: automationID, runID: runID)
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }), window.screen != screen {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        showWindow(nil)
        Frontmost.show(window)
    }

    // MARK: Keys

    private var keyMonitor: Any?
    func windowDidBecomeKey(_ notification: Notification) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
    func windowWillClose(_ notification: Notification) { windowDidResignKey(notification) }

    /// ⌘N new, ⌘R run now, Return edits, ⌫ asks to delete. Text fields and sheets keep their own keys.
    private func handle(_ event: NSEvent) -> Bool {
        guard window?.attachedSheet == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "n" { model.newAutomation(); return true }
        if flags == .command, key == "r" { model.runSelected(); return true }
        guard flags.isEmpty, !(window?.firstResponder is NSTextView) else { return false }
        switch event.keyCode {
        case 51, 117: // ⌫ and ⌦
            guard model.section == .all, model.selectedAutomationID != nil else { return false }
            model.requestDeleteSelected(); return true
        case 36, 76: // Return
            guard model.section == .all, let id = model.selectedAutomationID else { return false }
            model.edit(id); return true
        default: return false
        }
    }

    // MARK: Snapshots

    /// The root view for `--snapshot-ui`. Demo mode shows invented data; otherwise it shows empty states.
    static func snapshotView(demo: Bool, section: AutomationsViewModel.Section = .needsYou) -> some View {
        let model = AutomationsViewModel(center: nil, quill: nil, demo: demo ? AutomationsDemoData.make() : nil)
        model.section = section
        switch section {
        case .needsYou: model.selectedRunID = demo ? AutomationsDemoData.approvalRunID : nil
        case .failed: model.selectedRunID = demo ? AutomationsDemoData.failedRunID : nil
        case .all: model.selectedAutomationID = demo ? "desktop-tidy-demo" : nil
        default: break
        }
        return AutomationsRootView(model: model).frame(width: 1240, height: 780)
    }

    /// The editor for `--snapshot-ui`, filled from a template.
    static func snapshotEditor(_ template: AutomationTemplate = .desktopTidy) -> some View {
        let model = AutomationsViewModel(center: nil, quill: nil, demo: AutomationsDemoData.make())
        return AutomationEditorView(model: model, draft: template.draft(bunPath: "/opt/homebrew/bin/bun"), dismiss: {})
    }
}
