import SwiftUI

/// The island outline. On a notch screen the top edge is flat with small outward
/// curves, so it reads as the notch itself growing. Without a notch every corner is round.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    var topFlare: CGFloat

    init(bottomRadius: CGFloat, topRadius: CGFloat = 0, topFlare: CGFloat = 0) {
        self.bottomRadius = bottomRadius; self.topRadius = topRadius; self.topFlare = topFlare
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(bottomRadius, AnimatablePair(topRadius, topFlare)) }
        set { bottomRadius = newValue.first; topRadius = newValue.second.first; topFlare = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.height / 2, rect.width / 2)
        let r = min(bottomRadius, limit)
        let t = min(topRadius, limit)
        let f = min(topFlare, rect.width / 4)
        // 0.55 gives a continuous, squircle-like corner rather than a circular arc.
        let k: CGFloat = 0.55
        var p = Path()
        if f > 0 {
            p.move(to: CGPoint(x: rect.minX - f, y: rect.minY))
            p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + f),
                       control1: CGPoint(x: rect.minX - f * (1 - k), y: rect.minY),
                       control2: CGPoint(x: rect.minX, y: rect.minY + f * (1 - k)))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + t))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                   control1: CGPoint(x: rect.minX, y: rect.maxY - r * (1 - k)),
                   control2: CGPoint(x: rect.minX + r * (1 - k), y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                   control1: CGPoint(x: rect.maxX - r * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: rect.maxX, y: rect.maxY - r * (1 - k)))
        if f > 0 {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
            p.addCurve(to: CGPoint(x: rect.maxX + f, y: rect.minY),
                       control1: CGPoint(x: rect.maxX, y: rect.minY + f * (1 - k)),
                       control2: CGPoint(x: rect.maxX + f * (1 - k), y: rect.minY))
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + t))
            p.addCurve(to: CGPoint(x: rect.maxX - t, y: rect.minY),
                       control1: CGPoint(x: rect.maxX, y: rect.minY + t * (1 - k)),
                       control2: CGPoint(x: rect.maxX - t * (1 - k), y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + t, y: rect.minY))
            p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + t),
                       control1: CGPoint(x: rect.minX + t * (1 - k), y: rect.minY),
                       control2: CGPoint(x: rect.minX, y: rect.minY + t * (1 - k)))
        }
        p.closeSubpath()
        return p
    }
}
