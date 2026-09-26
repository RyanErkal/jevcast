import CoreGraphics
import Foundation
import LauncherCore

/// The Hyper key event tap. It runs on its own thread so a busy main thread never delays typing.
/// The callback only decides and hands actions to the main queue; `HyperKeyState` holds the rules.
final class HyperKeyTap: @unchecked Sendable {
    /// Marks keys Jevcast posts, so the tap lets them through.
    static let syntheticMark: Int64 = 0x4A45_5648
    typealias Handler = @MainActor (HyperKeyState.Decision, CGEventFlags) -> Void

    private let lock = NSLock()
    private var state = HyperKeyState()
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    var isRunning: Bool { lock.withLock { port != nil } }

    func setTable(_ table: [UInt16: HyperAction]) { lock.withLock { state.table = table } }

    /// Creates the tap. Returns false when macOS refuses it, usually for want of Accessibility or Input Monitoring.
    func start() -> Bool {
        if isRunning { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HyperKeyTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        lock.withLock { self.port = port }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { ready.signal(); return }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            self.lock.withLock { self.loop = loop }
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Jevcast Hyper key"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { self.port = nil; self.loop = nil; _ = state.reset() }
            return (self.port, self.loop)
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let (port, decision) = lock.withLock { (self.port, state.reset()) }
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            deliver(decision, flags: [])
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMark else { return Unmanaged.passUnretained(event) }
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let input: HyperKeyState.Event = type == .keyDown
                ? .keyDown(code, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) : .keyUp(code)
            let decision = lock.withLock { state.handle(input) }
            deliver(decision, flags: event.flags)
            return decision.swallow ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func deliver(_ decision: HyperKeyState.Decision, flags: CGEventFlags) {
        guard decision.perform != nil || decision.light != nil else { return }
        let handler = handler
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(decision, flags) } }
    }

    /// Posts a key press as if typed, with Shift, Control, Option, and Command kept from the real press.
    @MainActor static func post(keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        var kept = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        // Arrow keys carry these on a real keyboard; apps read selection keys from them.
        if (123...126).contains(keyCode) { kept.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = kept
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMark)
            event.post(tap: .cghidEventTap)
        }
    }
}
