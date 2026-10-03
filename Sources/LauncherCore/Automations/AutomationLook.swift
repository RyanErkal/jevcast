import Foundation

/// The colours an automation's icon may use. The name is stored; the app draws it.
/// An accent is identity only: failure, review, and success always show with their own badge and words, so a red
/// accent never reads as a failure.
public enum AutomationAccent: String, CaseIterable, Codable, Sendable {
    // The first ten follow the order of the older ID-based palette, so `fallback(for:)` keeps each row's colour.
    case blue, indigo, purple, pink, orange, teal, green, cyan, mint, brown, red, graphite

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The colour an automation without a saved accent has always shown: a stable pick from its ID.
    public static func fallback(for id: String) -> AutomationAccent {
        let legacy = Array(allCases.prefix(10))
        let hash = id.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return legacy[Int(hash % UInt32(legacy.count))]
    }
}

/// SF Symbol names as stored. The app checks that a symbol exists; this checks only its form.
public enum AutomationSymbol {
    public static let fallback = "gearshape.2"

    /// Lowercase letters, digits, and dots, such as "chart.bar.xaxis".
    public static func isWellFormed(_ name: String) -> Bool {
        (1...64).contains(name.count) && !name.hasPrefix(".") && !name.hasSuffix(".") && !name.contains("..")
            && name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }
    }
}

extension Automation {
    /// The saved accent when it is a known name, otherwise nil.
    public var accentChoice: AutomationAccent? { accent.flatMap(AutomationAccent.init(rawValue:)) }
    /// The accent to draw: the saved one, or the stable fallback for its ID.
    public var resolvedAccent: AutomationAccent { accentChoice ?? .fallback(for: id) }
}

extension Automation.Kind {
    /// The kind of work in a few words. Alerts show it in place of the name when names are hidden,
    /// because it comes from the definition's type, never from names, folders, or output.
    public var category: String {
        switch self {
        case .script, .scriptWithDiagnosis: return "Script"
        case .agent: return "Agent task"
        case .staged: return "Report workflow"
        }
    }

    /// Used when the automation's definition cannot be read.
    public static let unknownCategory = "Automation"
}
