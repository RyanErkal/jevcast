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
        var listFraction: CGFloat { self == .widerMessage ? 0.26 : 0.36 }
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
    /// Whether the mailbox sidebar shows. It stays as you left it, also after a restart.
    static let sidebarKey = "mailShowsSidebar"
    /// Whether the composer's formatting bar shows. Hidden by default.
    static let formattingKey = "mailShowsFormatting"
    /// Column widths you dragged to, in points. Double-clicking a divider removes them.
    static let sidebarWidthKey = "mailSidebarWidth"
    /// The list's width under one layout. Each `Split` keeps its own.
    static func listWidthKey(_ split: Split) -> String { "mailListWidth." + split.rawValue }
    /// One list width and the `Split` it was dragged under, as earlier builds kept them. Read once
    /// and moved to the layout's own key.
    static let legacyListWidthKey = "mailListWidth"
    static let legacyListWidthSplitKey = "mailListWidthSplit"
    static let zoomRange: ClosedRange<Double> = 0.75...1.5
    /// One press of ⌘+ or ⌘−, the same step as the reader's Text Size menu items.
    static let zoomStep = 0.25

    static var markRead: MarkRead {
        UserDefaults.standard.object(forKey: markReadKey).flatMap { ($0 as? Double).flatMap(MarkRead.init(rawValue:)) } ?? .oneSecond
    }
    static var split: Split { UserDefaults.standard.string(forKey: splitKey).flatMap(Split.init(rawValue:)) ?? .balanced }

    static func clampZoom(_ value: Double) -> Double { min(max(value, zoomRange.lowerBound), zoomRange.upperBound) }

    /// The message text size, shown in the reader's ⋯ menu. ⌘+, ⌘−, and ⌘0 change it.
    static var zoom: Double {
        get { clampZoom(UserDefaults.standard.object(forKey: zoomKey) as? Double ?? 1) }
        set { UserDefaults.standard.set(clampZoom(newValue), forKey: zoomKey) }
    }

    enum ZoomChange { case larger, smaller, actualSize }

    /// The size after one zoom key.
    static func zoom(_ current: Double, _ change: ZoomChange) -> Double {
        switch change {
        case .larger: return clampZoom(clampZoom(current) + zoomStep)
        case .smaller: return clampZoom(clampZoom(current) - zoomStep)
        case .actualSize: return 1
        }
    }
}
