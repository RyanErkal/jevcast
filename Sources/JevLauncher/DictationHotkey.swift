import AppKit
import LauncherCore

/// Watches Right Command for hold-to-dictate. The decisions live in `DictationHold`.
/// Global key monitors need Accessibility; without it only the app's own windows are seen.
@MainActor
final class DictationHotkey {
    private var machine = DictationHold()
    private var monitors: [Any] = []
    private let onOutput: (DictationHold.Output) -> Void
    /// NX_DEVICERCMDKEYMASK: set while the right Command key is down.
    private static let rightCommandMask: UInt = 0x10

    init(onOutput: @escaping (DictationHold.Output) -> Void) { self.onOutput = onOutput }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event); return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if machine.isHolding { onOutput(.cancel) }
        machine = DictationHold()
    }

    private func handle(_ event: NSEvent) {
        let input: DictationHold.Event
        if event.type == .flagsChanged, event.keyCode == DictationHold.rightCommandKeyCode {
            input = .rightCommand(down: event.modifierFlags.rawValue & Self.rightCommandMask != 0, at: event.timestamp)
        } else {
            input = .otherKey
        }
        if let output = machine.handle(input) { onOutput(output) }
    }
}
