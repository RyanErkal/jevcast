import AppKit

/// Owns the click catchers for one launcher session. A click is consumed in
/// full before dismissal so its mouse-up cannot reach an underlying control.
@MainActor
final class LauncherBackdrop {
    private var windows: [NSWindow] = []
    func show(dismiss: @escaping () -> Void) {
        close()
        for screen in NSScreen.screens {
            let window = BackdropWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .black.withAlphaComponent(0.01)
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            let catcher = ClickCatcher(frame: NSRect(origin: .zero, size: screen.frame.size))
            catcher.dismiss = dismiss
            window.contentView = catcher
            window.orderFrontRegardless()
            windows.append(window)
        }
    }
    func close() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }
}

private final class BackdropWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ClickCatcher: NSView {
    var dismiss: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { dismiss?() }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) { dismiss?() }
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) { dismiss?() }
    override func scrollWheel(with event: NSEvent) {}
}
