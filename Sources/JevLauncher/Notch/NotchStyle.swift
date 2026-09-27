import SwiftUI

/// What the island draws. `collapsed` is the notch itself; `compact` is the pill beside it.
/// The others follow `NotchState.Mode`.
enum NotchMode: Equatable {
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
/// Colour is an accent only: the icon glyph, the progress ring, and a destructive button.
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

    static func tint(_ phase: NotchPresentation.Phase) -> Color {
        switch phase {
        case .question, .approval: return Color(red: 1.0, green: 0.74, blue: 0.30)
        case .failure: return Color(red: 1.0, green: 0.42, blue: 0.38)
        case .success: return Color(red: 0.40, green: 0.86, blue: 0.52)
        case .running, .info: return Color(red: 0.45, green: 0.68, blue: 1.0)
        }
    }

    static let destructive = tint(.failure)

    static func statusText(_ p: NotchPresentation) -> String {
        switch p.phase {
        case .running: return p.progress.flatMap { $0.isFinite ? "\(Int((min(1, max(0, $0)) * 100).rounded()))%" : nil } ?? "Running"
        case .question: return "Question"
        case .approval: return "Review"
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

    /// A critically damped spring: the shape grows out of the notch and settles without a bounce.
    static func morph(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.92, blendDuration: 0.1)
    }

    /// Content fades in once the shape has mostly grown, and fades out at once.
    static func contentFade(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
                                              removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
}

/// The island's solid black shape, a hairline edge for dark wallpapers, and a neutral shadow while open.
struct NotchSurface: View {
    let shape: NotchShape
    let mode: NotchMode

    var body: some View {
        shape.fill(Color.black)
            .overlay { shape.stroke(NotchStyle.hairline, lineWidth: 0.5).opacity(mode.isOpen ? 1 : 0) }
            .shadow(color: .black.opacity(mode.isOpen ? 0.35 : 0), radius: 16, y: 6)
    }
}
