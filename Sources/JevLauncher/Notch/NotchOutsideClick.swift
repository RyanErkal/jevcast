import AppKit

/// Reports a mouse press anywhere while the island is open, so the controller can close it on a click elsewhere.
/// Both monitors only observe: the press still reaches the app or window it was meant for, nothing is swallowed, and
/// Jevcast is never activated. Mouse monitors need no Accessibility permission. The global monitor sees other apps;
/// the local one sees Jevcast's own windows, including the island, which the controller tells apart by its outline.
@MainActor
final class NotchOutsideClick {
    private var monitors: [Any] = []
    private let handler: @MainActor (CGPoint) -> Void

    init(_ handler: @escaping @MainActor (CGPoint) -> Void) { self.handler = handler }

    deinit { for monitor in monitors { NSEvent.removeMonitor(monitor) } }

    var isWatching: Bool { !monitors.isEmpty }

    /// Starts watching. Does nothing while already watching, so each press is reported once.
    func start() {
        guard monitors.isEmpty else { return }
        let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: presses, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: presses, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.report() }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    /// Screen coordinates, as `NotchGeometry.contains` takes them.
    private func report() { handler(NSEvent.mouseLocation) }
}
