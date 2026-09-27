import SwiftUI

/// The three sizes of the island.
enum NotchMode: Equatable { case collapsed, compact, expanded }

/// Colours, sizes, and motion for the notch island.
enum NotchStyle {
    static let expandedWidth: CGFloat = 380
    /// Fits inside `NotchGeometry.cardBody` (92), so the panel frame does not change.
    static let expandedBody: CGFloat = 90
    static let briefBody: CGFloat = 56
    /// Space each side of the notch in compact mode, for the icon and the status.
    static let compactWing: CGFloat = 66
    /// Pill height and width on a screen without a notch.
    static let pillHeight: CGFloat = 34
    static let pillWidth: CGFloat = 280
    static let pillTopGap: CGFloat = 6
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

    static func size(_ mode: NotchMode, _ p: NotchPresentation, _ g: NotchGeometry) -> CGSize {
        let top = g.hasNotch ? g.notchHeight : 0
        switch mode {
        case .collapsed:
            return g.hasNotch ? CGSize(width: g.notchWidth, height: g.notchHeight) : CGSize(width: 120, height: pillHeight)
        case .compact:
            return g.hasNotch ? CGSize(width: g.notchWidth + compactWing * 2, height: g.notchHeight)
                              : CGSize(width: pillWidth, height: pillHeight)
        case .expanded:
            return CGSize(width: max(expandedWidth, g.notchWidth + 40), height: top + (p.isBrief ? briefBody : expandedBody))
        }
    }

    static func bottomRadius(_ mode: NotchMode, hasNotch: Bool) -> CGFloat {
        switch mode {
        case .collapsed: return hasNotch ? 10 : pillHeight / 2
        case .compact: return hasNotch ? 14 : pillHeight / 2
        case .expanded: return 28
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
                if !reduceTransparency && mode == .expanded {
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
            .shadow(color: reduceTransparency ? .clear : tint.opacity(open ? 0.30 : 0), radius: mode == .expanded ? 12 : 7, y: 2)
            .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 10, y: 5)
    }
}
