import AppKit
import SwiftUI

/// The Jevcast mail window. It reads while open and stops watching Mail when it closes.
@MainActor
final class MailWindow: NSWindowController, NSWindowDelegate {
    let model: MailModel

    init(model: MailModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Mail"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("JevcastMail")
        // A hosting controller brings the SwiftUI toolbar and search field into the window.
        let hosting = NSHostingController(rootView: MailRootView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Opens the window, optionally on one message.
    func show(select rowID: Int64? = nil, compose address: String? = nil) {
        model.start()
        if let rowID { model.open(rowID) }
        // An open draft is kept; a contact's address fills a new one only when none is open.
        if let address, model.draft == nil { model.compose(to: address) }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.stop() }
}
