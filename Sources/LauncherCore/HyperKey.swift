import Foundation

/// What a Hyper key combination does. Stored as JSON in preferences.
public enum HyperAction: Codable, Hashable, Sendable {
    /// A Jevcast action from `HyperBuiltIn`, by ID.
    case builtIn(String)
    /// Opens the app with this bundle ID.
    case openApp(String)
    /// Posts this key code, with the other modifiers still held.
    case sendKey(UInt16)
}

/// The fixed Jevcast actions a Hyper key can run. IDs are stored, so never rename them.
public enum HyperBuiltIn: String, CaseIterable, Sendable {
    case launcher, mail, calendar, automations, clipboard
    case leftHalf = "window.left-half", rightHalf = "window.right-half"
    case topHalf = "window.top-half", bottomHalf = "window.bottom-half"
    case maximize = "window.maximize"

    public var title: String {
        switch self {
        case .launcher: return "Open launcher"
        case .mail: return "Open Mail view"
        case .calendar: return "Open Calendar view"
        case .automations: return "Open Automations"
        case .clipboard: return "Open Clipboard view"
        case .leftHalf: return "Window left half"
        case .rightHalf: return "Window right half"
        case .topHalf: return "Window top half"
        case .bottomHalf: return "Window bottom half"
        case .maximize: return "Maximise window"
        }
    }
    /// The window action for window IDs.
    public var windowAction: WindowAction? {
        rawValue.hasPrefix("window.") ? WindowAction(rawValue: String(rawValue.dropFirst("window.".count))) : nil
    }
}

/// One key on the Hyper layer.
public struct HyperBinding: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var keyCode: UInt16
    public var action: HyperAction
    public init(id: UUID = UUID(), keyCode: UInt16, action: HyperAction) {
        self.id = id; self.keyCode = keyCode; self.action = action
    }
}

public enum HyperLayer {
    /// F18: Caps Lock is remapped to it, and holding it is Hyper.
    public static let hyperKeyCode: UInt16 = 79

    public static let defaults: [HyperBinding] = [
        .init(keyCode: 46, action: .builtIn(HyperBuiltIn.mail.rawValue)),          // M
        .init(keyCode: 8, action: .builtIn(HyperBuiltIn.calendar.rawValue)),       // C
        .init(keyCode: 49, action: .builtIn(HyperBuiltIn.launcher.rawValue)),      // Space
        .init(keyCode: 0, action: .builtIn(HyperBuiltIn.automations.rawValue)),    // A
        .init(keyCode: 9, action: .builtIn(HyperBuiltIn.clipboard.rawValue)),      // V
        .init(keyCode: 4, action: .sendKey(123)),                                  // H → ←
        .init(keyCode: 38, action: .sendKey(125)),                                 // J → ↓
        .init(keyCode: 40, action: .sendKey(126)),                                 // K → ↑
        .init(keyCode: 37, action: .sendKey(124)),                                 // L → →
        .init(keyCode: 123, action: .builtIn(HyperBuiltIn.leftHalf.rawValue)),
        .init(keyCode: 124, action: .builtIn(HyperBuiltIn.rightHalf.rawValue)),
        .init(keyCode: 126, action: .builtIn(HyperBuiltIn.topHalf.rawValue)),
        .init(keyCode: 125, action: .builtIn(HyperBuiltIn.bottomHalf.rawValue)),
        .init(keyCode: 36, action: .builtIn(HyperBuiltIn.maximize.rawValue))       // Return
    ]

    /// Defaults added after the first release, with the version that added them. A stored layer gets
    /// each one once, and only when the user has nothing on that key.
    public static let addedDefaults: [(version: Int, keyCode: UInt16, action: HyperAction)] = [
        (1, 9, .builtIn(HyperBuiltIn.clipboard.rawValue))
    ]
    public static var addedDefaultsVersion: Int { addedDefaults.map(\.version).max() ?? 0 }

    /// The user's layer with defaults newer than `seenVersion` added where their key is free.
    public static func addingNewDefaults(to bindings: [HyperBinding], seenVersion: Int) -> [HyperBinding] {
        var result = bindings
        for added in addedDefaults where added.version > seenVersion && !result.contains(where: { $0.keyCode == added.keyCode }) {
            result.append(HyperBinding(keyCode: added.keyCode, action: added.action))
        }
        return result
    }

    /// Key codes used by more than one binding.
    public static func duplicateKeys(_ bindings: [HyperBinding]) -> Set<UInt16> {
        var seen = Set<UInt16>(), duplicates = Set<UInt16>()
        for binding in bindings where !seen.insert(binding.keyCode).inserted { duplicates.insert(binding.keyCode) }
        return duplicates
    }

    /// The first binding for each key; a later duplicate never runs.
    public static func table(_ bindings: [HyperBinding]) -> [UInt16: HyperAction] {
        var table: [UInt16: HyperAction] = [:]
        for binding in bindings where table[binding.keyCode] == nil { table[binding.keyCode] = binding.action }
        return table
    }

    /// Keys a "Send key" action may post.
    public static let sendableKeys: [UInt16] = [123, 124, 126, 125, 36, 53, 51, 117, 48, 116, 121, 115, 119]

    /// A short printable name for an ANSI key code.
    public static func keyName(_ code: UInt16) -> String {
        if let name = names[code] { return name }
        return "Key \(code)"
    }
    private static let names: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}

/// The key decisions for the event tap. Pure, so tests drive it with key codes.
/// F18 is always swallowed. While it is held, a mapped key's down and up are swallowed and its action runs.
public struct HyperKeyState: Sendable {
    public enum Event: Equatable, Sendable {
        case keyDown(UInt16, isRepeat: Bool)
        case keyUp(UInt16)
    }
    public struct Decision: Equatable, Sendable {
        public var swallow: Bool
        public var perform: HyperAction?
        /// The Caps Lock light: `true` on, `false` off, `nil` unchanged.
        public var light: Bool?
        public init(swallow: Bool, perform: HyperAction? = nil, light: Bool? = nil) {
            self.swallow = swallow; self.perform = perform; self.light = light
        }
        public static let pass = Decision(swallow: false)
    }

    public var table: [UInt16: HyperAction]
    public private(set) var hyperDown = false
    /// Keys whose down was swallowed, so their up is swallowed too, even after Hyper is let go.
    public private(set) var held: Set<UInt16> = []
    public init(table: [UInt16: HyperAction] = [:]) { self.table = table }

    public mutating func handle(_ event: Event) -> Decision {
        switch event {
        case .keyDown(HyperLayer.hyperKeyCode, let isRepeat):
            if isRepeat, hyperDown { return Decision(swallow: true) }
            hyperDown = true
            return Decision(swallow: true, light: true)
        case .keyUp(HyperLayer.hyperKeyCode):
            hyperDown = false
            return Decision(swallow: true, light: false)
        case .keyDown(let code, let isRepeat):
            if held.contains(code) {
                // A held arrow key repeats; other actions run once per press.
                guard isRepeat, case .sendKey = table[code] else { return Decision(swallow: true) }
                return Decision(swallow: true, perform: table[code])
            }
            guard hyperDown, let action = table[code] else { return .pass }
            held.insert(code)
            return Decision(swallow: true, perform: action)
        case .keyUp(let code):
            return held.remove(code) != nil ? Decision(swallow: true) : .pass
        }
    }

    /// The tap stopped seeing keys, for example after a timeout: forget what was held.
    public mutating func reset() -> Decision {
        let wasDown = hyperDown
        hyperDown = false; held = []
        return Decision(swallow: false, light: wasDown ? false : nil)
    }
}

/// Merges Jevcast's Caps Lock → F18 entry into the user's `hidutil` UserKeyMapping and takes it out again.
public enum HIDKeyMapping {
    public static let capsLock: Int64 = 0x700000039
    public static let f18: Int64 = 0x70000006D
    public static let srcKey = "HIDKeyboardModifierMappingSrc"
    public static let dstKey = "HIDKeyboardModifierMappingDst"

    public struct Entry: Equatable, Sendable {
        public var src: Int64
        public var dst: Int64
        public init(src: Int64, dst: Int64) { self.src = src; self.dst = dst }
    }

    /// Reads `hidutil property --get UserKeyMapping` output: "(null)", an old-style plist array, or JSON.
    /// Returns nil when the text cannot be read, so callers never overwrite mappings they did not understand.
    public static func parse(_ output: String) -> [Entry]? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "(null)" { return [] }
        guard let data = text.data(using: .utf8),
              let array = (text.hasPrefix("[") ? try? JSONSerialization.jsonObject(with: data)
                           : try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any] else { return nil }
        var entries: [Entry] = []
        for item in array {
            guard let dictionary = item as? [String: Any],
                  let src = number(dictionary[srcKey]), let dst = number(dictionary[dstKey]) else { return nil }
            entries.append(Entry(src: src, dst: dst))
        }
        return entries
    }

    private static func number(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String {
            if string.lowercased().hasPrefix("0x") { return Int64(string.dropFirst(2), radix: 16) }
            return Int64(string)
        }
        return nil
    }

    /// The mapping with Caps Lock → F18, other entries kept, and the Caps Lock entry it replaced.
    public static func adding(to current: [Entry]) -> (entries: [Entry], replacedCaps: Entry?) {
        let replaced = current.first { $0.src == capsLock && $0.dst != f18 }
        return (current.filter { $0.src != capsLock } + [Entry(src: capsLock, dst: f18)], replaced)
    }

    /// The mapping without Jevcast's entry, with the user's earlier Caps Lock entry put back.
    public static func removing(from current: [Entry], restore previous: Entry?) -> [Entry] {
        let kept = current.filter { !($0.src == capsLock && $0.dst == f18) }
        guard let previous, !kept.contains(where: { $0.src == capsLock }) else { return kept }
        return kept + [previous]
    }

    public static func isApplied(_ entries: [Entry]) -> Bool { entries.contains(Entry(src: capsLock, dst: f18)) }

    /// The argument for `hidutil property --set`.
    public static func setArgument(_ entries: [Entry]) -> String {
        let items = entries.map { "{\"\(srcKey)\":\($0.src),\"\(dstKey)\":\($0.dst)}" }
        return "{\"UserKeyMapping\":[" + items.joined(separator: ",") + "]}"
    }
}
