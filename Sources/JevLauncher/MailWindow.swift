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
        // It opens on the Space you are using, over the window you are in.
        window.collectionBehavior = [.moveToActiveSpace]
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
        guard let window else { return }
        // On the display with the pointer, in front of the app you were using.
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }), window.screen != screen {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        showWindow(nil)
        Frontmost.show(window)
    }

    func windowWillClose(_ notification: Notification) { model.stop() }

    private var keyMonitor: Any?
    func windowDidBecomeKey(_ notification: Notification) {
        model.windowIsKey = true
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        model.windowIsKey = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Keys for checking mail. Typing in the search field or a reply keeps its own keys.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags == .command, event.charactersIgnoringModifiers == "f" { model.searching = true; return true }
        let typing = window?.firstResponder is NSTextView || model.draft != nil
        if event.keyCode == 53 { // Escape: leave the search, then close.
            if model.searching || !model.search.isEmpty { model.search = ""; model.searching = false; window?.makeFirstResponder(nil); return true }
            if model.draft == nil { window?.performClose(nil); return true }
            return false
        }
        guard !typing, flags.isEmpty else { return false }
        switch event.keyCode {
        case 125: model.moveSelection(1); return true           // ↓
        case 126: model.moveSelection(-1); return true          // ↑
        case 51, 117: model.delete(); return true               // ⌫ and ⌦
        case 36, 76: model.openInMail(); return true            // Return
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": model.moveSelection(1)
        case "k": model.moveSelection(-1)
        case "e": model.archive()
        case "r": model.reply(all: event.modifierFlags.contains(.shift))
        case "u": model.toggleRead()
        case "/": model.searching = true
        default: return false
        }
        return true
    }
}
