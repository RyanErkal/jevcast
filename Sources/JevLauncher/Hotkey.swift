import AppKit
import Carbon

/// Launcher shortcut choices. Raw values match the Int tags stored before this enum existed.
enum Hotkey: Int, CaseIterable, Identifiable {
    case controlShiftSpace = 0, optionSpace = 1, commandSpace = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .controlShiftSpace: return "Control–Shift–Space"
        case .optionSpace: return "Option–Space"
        case .commandSpace: return "Command–Space"
        }
    }
    var keyCode: UInt32 { UInt32(kVK_Space) }
    var keyEquivalent: String { " " }
    var carbonModifiers: UInt32 {
        switch self {
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        case .optionSpace: return UInt32(optionKey)
        case .commandSpace: return UInt32(cmdKey)
        }
    }
    var menuModifiers: NSEvent.ModifierFlags {
        switch self {
        case .controlShiftSpace: return [.control, .shift]
        case .optionSpace: return [.option]
        case .commandSpace: return [.command]
        }
    }
}

/// Make-before-break shortcut change: the new shortcut is registered while the
/// old one is still held, and the old one is released only on success.
enum HotkeySwap {
    enum Outcome<Token> {
        case unchanged
        case switched(Hotkey, Token)
        /// Registration failed. The old shortcut, if any, stays active; revert the preference to it.
        case failed(keep: Hotkey?)
    }
    static func apply<Token>(requested: Hotkey, active: (hotkey: Hotkey, token: Token)?,
                             register: (Hotkey) -> Token?, unregister: (Token) -> Void) -> Outcome<Token> {
        if let active, active.hotkey == requested { return .unchanged }
        guard let token = register(requested) else { return .failed(keep: active?.hotkey) }
        if let active { unregister(active.token) }
        return .switched(requested, token)
    }
}

/// Carbon global shortcuts with per-shortcut release.
@MainActor
final class HotkeyCenter {
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var callbacks: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private let signature: OSType = 0x4A45564B
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            guard id.signature == center.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { center.callbacks[id.id]?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(key: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> UInt32? {
        nextID &+= 1
        let id = nextID
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return nil }
        references[id] = reference; callbacks[id] = callback
        return id
    }
    func unregister(_ id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        callbacks[id] = nil
    }
    func clear() { references.keys.forEach(unregister) }
}
