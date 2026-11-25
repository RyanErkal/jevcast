import AppKit
import SwiftUI

/// Notices when you scroll or click in the open message, with a trackpad, a mouse wheel, or a
/// click, so a message the model chose by itself counts as read once you use it. It watches
/// AppKit's events only while the reader is on screen, and only events inside the reader. Layout
/// and scrolling done by code send no events, so they never count. No script runs in the page.
struct MailReaderActivity: NSViewRepresentable {
    let onAction: @MainActor () -> Void

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.onAction = onAction
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) { view.onAction = onAction }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    /// The event kinds that count as using the message.
    static let kinds: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// True when an event of `type`, at `point` in the reader's own coordinates, is you using the
    /// message: a scroll or a click inside the reader's bounds.
    static func counts(_ type: NSEvent.EventType, at point: NSPoint, in bounds: NSRect) -> Bool {
        [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) && bounds.contains(point)
    }

    final class Watcher: NSView {
        var onAction: (@MainActor () -> Void)?
        private var monitor: Any?

        // The watcher draws nothing and takes no clicks; it only listens.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: MailReaderActivity.kinds) { [weak self] event in
                // Local monitors run on the main thread, before the event goes on unchanged.
                MainActor.assumeIsolated { self?.notice(event) }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Counts `event` when it happened in this window, inside the reader.
        func notice(_ event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
            let point = convert(event.locationInWindow, from: nil)
            if MailReaderActivity.counts(event.type, at: point, in: bounds) { onAction?() }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
