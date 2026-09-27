import AppKit
import SwiftUI

/// The Automations window: background automations, runs that need you, Quill tasks, Codex, and dashboards.
@MainActor
final class AutomationsWindow: NSWindowController, NSWindowDelegate {
    let center: AutomationCenter?
    let quill: QuillTaskCenter?
    let model: AutomationsViewModel

    /// Opens Quill's new-task flow. Set by the app.
    var onNewQuillTask: (() -> Void)? {
        get { model.onNewQuillTask }
        set { model.onNewQuillTask = newValue }
    }

    /// The default size, and the smallest size that fits the sidebar, the list, and the detail side by side.
    nonisolated static let defaultSize = NSSize(width: 1240, height: 780)
    nonisolated static let minimumSize = NSSize(width: 980, height: 560)
    static let autosaveName = "JevcastAutomations"

    convenience init(center: AutomationCenter, quill: QuillTaskCenter) {
        self.init(model: AutomationsViewModel(center: center, quill: quill), autosaveName: Self.autosaveName)
    }

    /// Also used by `--capture-automations` with a demo model, so the capture takes the same path as Hyper+A.
    init(model: AutomationsViewModel, autosaveName: String) {
        self.center = model.center; self.quill = model.quill
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Automations"
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        let hosting = NSHostingController(rootView: AutomationsRootView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // The window sets its own size; SwiftUI only reports the minimum.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(Self.defaultSize)
        // Read the saved frame first, then check it. A frame saved by an older build can be too small,
        // which makes the split view hide its sidebar.
        let restored = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let frame = Self.usableFrame(saved: restored ? window.frame : nil, visible: visible, contentSize: Self.defaultSize, window: window)
        window.setFrame(frame, display: false)
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The frame to open at: the saved one when it is at least the minimum size and on screen,
    /// otherwise the default size centred on the visible screen area.
    static func usableFrame(saved: NSRect?, visible: NSRect?, minimum: NSSize = minimumSize, fallback: NSSize) -> NSRect {
        if let saved, saved.width >= minimum.width, saved.height >= minimum.height,
           visible.map({ $0.insetBy(dx: -1, dy: -1).contains(saved) }) ?? true {
            return saved
        }
        guard let visible else { return NSRect(origin: .zero, size: fallback) }
        let size = NSSize(width: min(fallback.width, max(minimum.width, visible.width - 40)),
                          height: min(fallback.height, max(minimum.height, visible.height - 40)))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func usableFrame(saved: NSRect?, visible: NSRect?, contentSize: NSSize, window: NSWindow) -> NSRect {
        let fallback = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        return usableFrame(saved: saved, visible: visible, fallback: fallback)
    }

    /// Opens the window, optionally on one automation or run.
    func show(automationID: String?, runID: String?) {
        center?.start()
        model.open(automationID: automationID, runID: runID)
        // Each open shows the sidebar at its ideal width, even if it was hidden last time.
        model.columnVisibility = .all
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? window.screen ?? NSScreen.main
        if let screen {
            var frame = Self.usableFrame(saved: window.frame, visible: screen.visibleFrame, contentSize: Self.defaultSize, window: window)
            if window.screen != screen, frame == window.frame {
                frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.midY - frame.height / 2)
            }
            if frame != window.frame { window.setFrame(frame, display: false) }
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

    /// The approval screen alone, with demo data, for `--snapshot-ui --demo`. Standalone, so it renders fully.
    static func snapshotApproval() -> some View {
        let model = AutomationsViewModel(center: nil, quill: nil, demo: AutomationsDemoData.make())
        return Group {
            if let run = model.run(AutomationsDemoData.approvalRunID) { ApprovalView(model: model, run: run) }
        }
        .frame(width: 760, height: 640)
    }

    /// The editor for `--snapshot-ui`, filled from a template.
    static func snapshotEditor(_ template: AutomationTemplate = .desktopTidy) -> some View {
        let model = AutomationsViewModel(center: nil, quill: nil, demo: AutomationsDemoData.make())
        return AutomationEditorView(model: model, draft: template.draft(), dismiss: {})
    }
}
