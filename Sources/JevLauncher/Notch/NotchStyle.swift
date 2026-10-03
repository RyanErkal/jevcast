import SwiftUI
import LauncherCore

/// What the island draws. `collapsed` is the notch itself; `compact` is the pill beside it.
/// The others follow `NotchState.Mode`.
enum NotchMode: Hashable {
    case collapsed, compact, card, detail, reply

    init(_ mode: NotchState.Mode) {
        switch mode {
        case .pill: self = .compact
        case .card: self = .card
        case .detail: self = .detail
        case .reply: self = .reply
        }
    }

    /// The state mode whose size this draws at. Collapsed has its own size.
    var stateMode: NotchState.Mode? {
        switch self {
        case .collapsed: return nil
        case .compact: return .pill
        case .card: return .card
        case .detail: return .detail
        case .reply: return .reply
        }
    }

    var isOpen: Bool { self != .collapsed && self != .compact }
}

/// Colours, sizes, and motion for the notch island. Sizes come from `NotchGeometry`, so the panel always fits the shape.
/// Two kinds of colour, never mixed: an automation's accent fills its icon (identity), and the state tint marks the
/// ring, a small badge, a destructive button, or an icon without an accent (state).
enum NotchStyle {
    static let buttonHeight: CGFloat = 28
    static let buttonMinWidth: CGFloat = 64
    /// Inside padding of the open island.
    static let padding: CGFloat = 16

    enum Font {
        static let title = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let message = SwiftUI.Font.system(size: 12)
        static let meta = SwiftUI.Font.system(size: 11, weight: .medium).monospacedDigit()
        static let button = SwiftUI.Font.system(size: 12, weight: .medium)
    }

    static let secondaryText = Color.white.opacity(0.6)
    static let metaText = Color.white.opacity(0.45)
    static let hairline = Color.white.opacity(0.08)
    /// The running ring is neutral, so neither an accent nor a state colour reads as progress.
    static let ring = Color.white.opacity(0.9)

    /// A secondary control's white fill: light, so it sits in the material; stronger with Increase Contrast.
    /// A press adds a little more, so a click reads before the action lands.
    static func controlFill(increased: Bool, hovering: Bool, pressed: Bool = false) -> Double {
        (increased ? (hovering ? 0.26 : 0.18) : (hovering ? 0.15 : 0.08)) + (pressed ? 0.06 : 0)
    }

    /// A secondary control's hairline edge.
    static func controlEdge(increased: Bool) -> Double { increased ? 0.4 : 0.12 }

    static func tint(_ phase: NotchPresentation.Phase) -> Color {
        switch phase {
        case .question, .approval, .review: return Color(red: 1.0, green: 0.74, blue: 0.30)
        case .failure: return Color(red: 1.0, green: 0.42, blue: 0.38)
        case .success: return Color(red: 0.40, green: 0.86, blue: 0.52)
        case .running, .info: return Color(red: 0.45, green: 0.68, blue: 1.0)
        }
    }

    static let destructive = tint(.failure)

    /// An automation's icon colour, or nil for none or an unknown name. Shared with the Automations window.
    static func accent(_ name: String?) -> Color? {
        name.flatMap(AutomationAccent.init(rawValue:)).map(AutomationTint.color)
    }

    /// "1:24" or "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "just now", "12m ago", "3h ago", "2d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(s / 60)m ago"
        case ..<86400: return "\(s / 3600)h ago"
        default: return "\(s / 86400)d ago"
        }
    }

    static func statusText(_ p: NotchPresentation) -> String {
        switch p.phase {
        case .running:
            if p.retry != nil { return "Retrying" }
            return p.progress.flatMap { $0.isFinite ? "\(Int((min(1, max(0, $0)) * 100).rounded()))%" : nil } ?? "Running"
        case .question: return "Question"
        case .approval, .review: return "Review"
        case .failure: return "Failed"
        case .success: return "Done"
        case .info: return "Alert"
        }
    }

    static func size(_ mode: NotchMode, _ alert: NotchAlert, _ g: NotchGeometry) -> CGSize {
        guard let stateMode = mode.stateMode else {
            return g.hasNotch ? CGSize(width: g.notchWidth, height: g.notchHeight) : CGSize(width: 120, height: NotchGeometry.pillBody)
        }
        return g.shapeSize(stateMode, alert: alert)
    }

    static func bottomRadius(_ mode: NotchMode, hasNotch: Bool) -> CGFloat {
        switch mode {
        case .collapsed: return hasNotch ? 10 : NotchGeometry.pillBody / 2
        case .compact: return hasNotch ? 12 : NotchGeometry.pillBody / 2
        case .card, .detail, .reply: return 24
        }
    }

    /// The outline for a mode: flat top with outward curves under a notch, round corners elsewhere.
    static func outline(_ mode: NotchMode, hasNotch: Bool) -> NotchShape {
        let radius = bottomRadius(mode, hasNotch: hasNotch)
        return NotchShape(bottomRadius: radius, topRadius: hasNotch ? 0 : radius, topFlare: hasNotch ? (mode.isOpen ? 10 : 7) : 0)
    }

    /// The ambient spring for mode changes. The shape's own width and height springs are in `NotchMotion`.
    static func morph(reduceMotion: Bool) -> Animation {
        NotchMotion.settle(closing: false, reduceMotion: reduceMotion)
    }
}

/// The outline drawn at a given size, top centre of whatever rect it fills. Hit testing and clipping use the same path.
struct NotchIslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var outline: NotchShape

    func path(in rect: CGRect) -> Path {
        outline.path(in: CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height))
    }
}
