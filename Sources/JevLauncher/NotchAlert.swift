import AppKit
import SwiftUI

// The model, queue, controller, geometry, state, and panel are in Notch/*.swift.

/// The card. Collapsed, it is the notch's own size and black, so it is invisible on a notch screen.
struct NotchAlertView: View {
    @ObservedObject var state: NotchState
    let action: (String) -> Void
    let hover: (Bool) -> Void

    var body: some View {
        let g = state.geometry
        let collapsedWidth = g.hasNotch ? g.notchWidth : 120
        let collapsedHeight = g.hasNotch ? g.notchHeight : 0
        let width = state.expanded ? max(NotchGeometry.cardWidth, g.notchWidth) : collapsedWidth
        let height = state.expanded ? g.notchHeight + NotchGeometry.cardBody : collapsedHeight
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                NotchShape(bottomRadius: state.expanded ? 26 : 10, topFlare: g.hasNotch ? 8 : 0)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(state.expanded ? 0.35 : 0), radius: 14, y: 6)
                if let alert = state.alert {
                    content(alert)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                        .frame(height: NotchGeometry.cardBody)
                        .opacity(state.expanded ? 1 : 0)
                        .scaleEffect(state.expanded ? 1 : 0.9, anchor: .top)
                }
            }
            .frame(width: width, height: max(height, 1))
            .offset(y: g.hasNotch ? 0 : (state.expanded ? 8 : -20))
            .onHover(perform: hover)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func content(_ alert: NotchAlert) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(tint(alert.tone).opacity(0.22)).frame(width: 38, height: 38)
                Image(systemName: alert.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint(alert.tone))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(alert.message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                ForEach(alert.actions, id: \.id) { item in
                    Button(item.title) { action(item.id) }
                        .buttonStyle(NotchButtonStyle(primary: item.primary, tint: tint(alert.tone)))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tint(_ tone: NotchAlert.Tone) -> Color {
        switch tone { case .attention: return .orange; case .failure: return .red; case .success: return .green; case .info: return .blue }
    }
}

struct NotchButtonStyle: ButtonStyle {
    let primary: Bool
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(primary ? tint : Color.white.opacity(0.14)))
            .foregroundStyle(primary ? Color.black : Color.white)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A rectangle with rounded bottom corners and small outward curves at the top, like the notch itself.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topFlare: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topFlare) }
        set { bottomRadius = newValue.first; topFlare = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        let f = min(topFlare, rect.width / 4)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - f, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + f), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX + f, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
