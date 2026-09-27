import Foundation

/// Reading settings for mail, stored in UserDefaults. Views read them with `@AppStorage` and these keys.
enum MailReading {
    enum Split: String, CaseIterable {
        case balanced, widerMessage, messageOnly
        var title: String {
            switch self {
            case .balanced: return "Balanced"
            case .widerMessage: return "Wider message"
            case .messageOnly: return "Message only on open"
            }
        }
        /// The list's share of the panel width in two panes.
        var listFraction: CGFloat { self == .widerMessage ? 0.34 : 0.5 }
    }

    /// When a previewed message counts as read. Seconds; 0 is on open, -1 is never.
    enum MarkRead: Double, CaseIterable {
        case off = -1, onOpen = 0, oneSecond = 1, threeSeconds = 3
        var title: String {
            switch self {
            case .off: return "Off"; case .onOpen: return "On open"
            case .oneSecond: return "After 1 second"; case .threeSeconds: return "After 3 seconds"
            }
        }
    }

    static let splitKey = "mailSplit"
    static let zoomKey = "mailZoom"
    static let fitKey = "mailFitWidth"
    static let markReadKey = "mailMarkReadAfter"
    static let plainKey = "mailPrefersPlain"
    static let zoomRange: ClosedRange<Double> = 0.75...1.5

    static var markRead: MarkRead {
        UserDefaults.standard.object(forKey: markReadKey).flatMap { ($0 as? Double).flatMap(MarkRead.init(rawValue:)) } ?? .oneSecond
    }
    static var split: Split { UserDefaults.standard.string(forKey: splitKey).flatMap(Split.init(rawValue:)) ?? .balanced }

    static func clampZoom(_ value: Double) -> Double { min(max(value, zoomRange.lowerBound), zoomRange.upperBound) }
}
