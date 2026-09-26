import AppKit
import SwiftUI

// Placeholder until the views branch merges its real `AutomationsWindow`. Delete at merge.
@MainActor
final class AutomationsWindow: NSWindowController {
    init(center: AutomationCenter, quill: QuillTaskCenter) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Automations"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Automations").frame(maxWidth: .infinity, maxHeight: .infinity))
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(automationID: String?, runID: String?) {
        window?.center()
        showWindow(nil)
        if let window { Frontmost.show(window) }
    }
}
