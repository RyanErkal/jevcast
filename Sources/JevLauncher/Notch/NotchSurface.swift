import SwiftUI

/// The island's edge: a thin white line that catches light like the rim of Liquid Glass. It is brightest just below the
/// notch (or along the top without one), quieter down the sides, and lifts again along the lower edge. Beside the notch
/// it is clear, so no bright line runs along the menu bar or the notch.
struct NotchRim: Equatable {
    struct Stop: Equatable {
        var opacity: Double
        var location: CGFloat
    }

    /// The line's white just below the notch band, down the sides, and at the bottom edge.
    var upper: Double
    var middle: Double
    var lower: Double
    var width: CGFloat
    /// A wider, fainter band just inside the line, as a share of the line's light, so the edge reads as depth
    /// rather than as a drawn outline.
    var inner: Double

    /// Points over which the clear band beside the notch fades into the rim.
    static let bandFade: CGFloat = 18
    /// The inner band's stroke width. Only its inside half shows.
    static let innerWidth: CGFloat = 3

    /// Increase Contrast firms the line, so the island's outline stays clear on a dark desktop.
    static func make(increaseContrast: Bool) -> NotchRim {
        increaseContrast
            ? NotchRim(upper: 0.5, middle: 0.36, lower: 0.44, width: 1, inner: 0.25)
            : NotchRim(upper: 0.22, middle: 0.07, lower: 0.14, width: 0.5, inner: 0.35)
    }

    /// The line's white over a shape `height` tall whose top `band` points sit beside the notch (0 without one).
    /// A shape that ends inside the band or its fade (as it grows or retracts) stops part way, so the band stays clear.
    func stops(height: CGFloat, band: CGFloat) -> [Stop] {
        let clear = [Stop(opacity: 0, location: 0), Stop(opacity: 0, location: 1)]
        guard height > 0 else { return clear }
        guard band > 0 else {
            return [Stop(opacity: upper, location: 0), Stop(opacity: middle, location: 0.5), Stop(opacity: lower, location: 1)]
        }
        guard height > band else { return clear }
        let solid = band / height
        guard height > band + Self.bandFade else {
            let reached = Double((height - band) / Self.bandFade)
            return [Stop(opacity: 0, location: 0), Stop(opacity: 0, location: solid), Stop(opacity: upper * reached, location: 1)]
        }
        let lit = (band + Self.bandFade) / height
        return [Stop(opacity: 0, location: 0), Stop(opacity: 0, location: solid), Stop(opacity: upper, location: lit),
                Stop(opacity: middle, location: (lit + 1) / 2), Stop(opacity: lower, location: 1)]
    }
}

/// False in offscreen renders, where window-server animations cannot draw.
private struct NotchLiveSurfaceKey: EnvironmentKey { static let defaultValue = true }

/// Snapshot demos only: draw as if Increase Contrast were on. Nil follows the system, which SwiftUI does not let a
/// view set.
struct NotchAccessibilityOverride: Equatable {
    var increaseContrast: Bool?
}

private struct NotchAccessibilityOverrideKey: EnvironmentKey { static let defaultValue = NotchAccessibilityOverride() }

extension EnvironmentValues {
    var notchLiveSurface: Bool {
        get { self[NotchLiveSurfaceKey.self] }
        set { self[NotchLiveSurfaceKey.self] = newValue }
    }

    var notchAccessibilityOverride: NotchAccessibilityOverride {
        get { self[NotchAccessibilityOverrideKey.self] }
        set { self[NotchAccessibilityOverrideKey.self] = newValue }
    }

    /// Increase Contrast, from the system or a snapshot override.
    var notchIncreaseContrast: Bool { notchAccessibilityOverride.increaseContrast ?? (colorSchemeContrast == .increased) }
}

/// The island's surface at its animated outline, back to front: a soft shadow outside the outline only, opaque black,
/// and the rim. The black is the same in every state and setting, so the island continues the hardware notch without a
/// seam, white text keeps full contrast over any desktop, and Reduce Transparency has nothing to remove.
/// It takes no pointer input; the island's content shape and the panel's outline test do that.
struct NotchSurface: View {
    let shape: NotchIslandShape
    /// The shape's animated height, notch included.
    let height: CGFloat
    /// The notch's height, or 0 on a screen without one.
    let band: CGFloat
    /// 0 closed or compact, 1 open. The rim and shadow fade in with it; the black does not change.
    let openness: CGFloat
    /// Pure black, fully opaque.
    static let fill = Color.black
    /// The outline's top flares reach past the island's frame. Each gradient layer overhangs the frame by this much
    /// before it is cut to the outline, so the flares keep their curve into the menu bar. A `Shape` fill draws there
    /// by itself.
    static let overhang: CGFloat = 16
    @Environment(\.notchIncreaseContrast) private var increaseContrast

    var body: some View {
        let rim = NotchRim.make(increaseContrast: increaseContrast)
        let line = rim.stops(height: height, band: band)
        ZStack(alignment: .top) {
            depth.opacity(Double(openness))
            shape.fill(Self.fill)
            Group {
                gradient(line.map { NotchRim.Stop(opacity: $0.opacity * rim.inner, location: $0.location) }, extra: NotchRim.innerWidth)
                    .mask { shape.stroke(lineWidth: NotchRim.innerWidth) }
                    .clipShape(shape)
                gradient(line, extra: rim.width)
                    .mask { shape.stroke(lineWidth: rim.width) }
            }
            .opacity(Double(openness))
        }
        .allowsHitTesting(false)
    }

    /// A vertical white gradient over the shape's height, top-aligned in the island's canvas and overhanging its sides.
    private func gradient(_ stops: [NotchRim.Stop], extra: CGFloat) -> some View {
        LinearGradient(stops: stops.map { Gradient.Stop(color: Color.white.opacity($0.opacity), location: $0.location) },
                       startPoint: .top, endPoint: .bottom)
            .frame(height: max(0, height + extra))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, -Self.overhang)
    }

    /// The shadow of the open shape, cut away inside it. Rasterised on the GPU; the margin keeps the shadow and the
    /// top flare inside the layer.
    private var depth: some View {
        ZStack {
            shape.fill(Color.black).shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            shape.fill(Color.black).blendMode(.destinationOut)
        }
        .compositingGroup()
        .padding(32).drawingGroup().padding(-32)
    }
}
