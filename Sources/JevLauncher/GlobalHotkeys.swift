import AppKit
import Carbon

@MainActor
final class GlobalHotkeys {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var callbacks: [UInt32: () -> Void] = [:]
    private let signature: OSType = 0x4A45564C
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let manager = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { manager.callbacks[id.id]?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func clear() {
        references.forEach { UnregisterEventHotKey($0) }; references = []; callbacks = [:]
    }
    @discardableResult func register(key: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> Bool {
        let id = UInt32(callbacks.count + 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references.append(reference); callbacks[id] = callback
        return true
    }
}
