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
enum NotchStyle {
    static let buttonHeight: CGFloat = 26

    static func tint(_ phase: NotchPresentation.Phase) -> Color {
        switch phase {
        case .question, .approval: return Color(red: 1.0, green: 0.72, blue: 0.24)
        case .failure: return Color(red: 1.0, green: 0.36, blue: 0.33)
        case .success: return Color(red: 0.33, green: 0.87, blue: 0.48)
        case .running, .info: return Color(red: 0.38, green: 0.64, blue: 1.0)
        }
    }

    static func statusText(_ p: NotchPresentation) -> String {
        switch p.phase {
        case .running: return p.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "Running"
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
        case .compact: return hasNotch ? 14 : NotchGeometry.pillBody / 2
        case .card, .detail, .reply: return 28
        }
    }

    /// A spring close to the system island: quick, one small overshoot.
    static func morph(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.44, dampingFraction: 0.76, blendDuration: 0.1)
    }
}

/// Tinted glow, inner highlight, and depth for the island's black shape.
/// Reduce Transparency keeps plain black with a hairline edge.
struct NotchSurface: View {
    let shape: NotchShape
    let tint: Color
    let mode: NotchMode
    let reduceTransparency: Bool

    var body: some View {
        let open = mode != .collapsed
        shape.fill(Color.black)
            .overlay {
                if !reduceTransparency && mode.isOpen {
                    // Soft tone light from the icon corner. A gradient, not a blur, so it costs nothing per frame.
                    RadialGradient(colors: [tint.opacity(0.20), .clear], center: UnitPoint(x: 0.1, y: 0.55), startRadius: 0, endRadius: 190)
                        .clipShape(shape)
                        .transition(.opacity)
                }
            }
            .overlay {
                shape.stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(reduceTransparency ? 0.18 : 0.12)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .opacity(open ? 1 : 0)
            }
            .shadow(color: reduceTransparency ? .clear : tint.opacity(open ? 0.30 : 0), radius: mode.isOpen ? 12 : 7, y: 2)
            .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 10, y: 5)
    }
}
