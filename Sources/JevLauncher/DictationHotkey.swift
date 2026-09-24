import AppKit
import LauncherCore

/// Watches Right Command for hold-to-dictate. The decisions live in `DictationHold`.
/// Global key monitors need Accessibility; without it only the app's own windows are seen.
@MainActor
final class DictationHotkey {
    private var machine = DictationHold()
    private var monitors: [Any] = []
    private var releaseCheck: Timer?
    private let onOutput: (DictationHold.Output) -> Void
    /// NX_DEVICERCMDKEYMASK: set while the right Command key is down.
    private static let rightCommandMask: UInt = 0x10

    init(onOutput: @escaping (DictationHold.Output) -> Void) { self.onOutput = onOutput }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        // A click counts as a chord too, so ⌘-click selects without recording.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
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
        releaseCheck?.invalidate(); releaseCheck = nil
        if machine.isHolding { onOutput(.cancel) }
        machine = DictationHold()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged, event.keyCode == DictationHold.rightCommandKeyCode {
            deliver(.rightCommand(down: event.modifierFlags.rawValue & Self.rightCommandMask != 0, at: event.timestamp))
        } else {
            deliver(.otherKey)
        }
    }

    private func deliver(_ input: DictationHold.Event) {
        if let output = machine.handle(input) { onOutput(output) }
        watchRelease()
    }

    /// Monitors miss the release in some cases, such as while another app uses secure input.
    /// While a hold records, check the keyboard itself: no Command key down means it ended.
    private func watchRelease() {
        guard machine.isHolding else { releaseCheck?.invalidate(); releaseCheck = nil; return }
        guard releaseCheck == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // The current keys, read from the window server whichever app is in front.
                guard let self, self.machine.isHolding, !NSEvent.modifierFlags.contains(.command) else { return }
                // NSEvent timestamps count from system start, like systemUptime.
                self.deliver(.rightCommand(down: false, at: ProcessInfo.processInfo.systemUptime))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseCheck = timer
    }
}
