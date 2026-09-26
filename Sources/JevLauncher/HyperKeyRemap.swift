import Foundation
import LauncherCore

/// Caps Lock → F18 through `hidutil`'s UserKeyMapping. Other mappings are kept.
/// A marker in UserDefaults records that the remap is on, so a launch after a crash can undo it.
enum HyperKeyRemap {
    static let activeKey = "hyperRemapActive"
    static let previousKey = "hyperRemapPreviousCaps"
    private static let hidutil = "/usr/bin/hidutil"

    enum Failure: Error { case unreadable, command(String) }

    static func isMarked(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: activeKey) }

    /// Adds the Caps Lock entry, remembering the user's own Caps Lock entry if there was one.
    static func apply(_ defaults: UserDefaults = .standard) throws {
        let current = try read()
        let merged = HIDKeyMapping.adding(to: current)
        if let replaced = merged.replacedCaps { defaults.set(NSNumber(value: replaced.dst), forKey: previousKey) }
        defaults.set(true, forKey: activeKey)
        if merged.entries != current { try write(merged.entries) }
    }

    /// Takes out only Jevcast's entry and puts back the earlier Caps Lock entry.
    static func remove(_ defaults: UserDefaults = .standard) throws {
        let current = try read()
        let previous = (defaults.object(forKey: previousKey) as? NSNumber).map { HIDKeyMapping.Entry(src: HIDKeyMapping.capsLock, dst: $0.int64Value) }
        let restored = HIDKeyMapping.removing(from: current, restore: previous)
        if restored != current { try write(restored) }
        defaults.removeObject(forKey: activeKey)
        defaults.removeObject(forKey: previousKey)
    }

    static func read() throws -> [HIDKeyMapping.Entry] {
        guard let entries = HIDKeyMapping.parse(try run(["property", "--get", "UserKeyMapping"])) else { throw Failure.unreadable }
        return entries
    }

    private static func write(_ entries: [HIDKeyMapping.Entry]) throws {
        _ = try run(["property", "--set", HIDKeyMapping.setArgument(entries)])
    }

    /// Runs hidutil with fixed arguments and no shell.
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hidutil)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw Failure.command(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }
}
