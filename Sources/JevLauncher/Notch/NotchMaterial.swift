import AppKit
import SwiftUI

/// How the open island's surface is drawn. A closed or compact island is always opaque black, so it continues the
/// hardware notch without a seam; only open cards and lists show a material.
enum NotchMaterial: Equatable {
    /// macOS 26 and later: Liquid Glass (`glassEffect`) in the island's own outline, under a dark smoke.
    case glass
    /// macOS 14 and 15: the dark behind-window material, masked to the outline, under the same smoke.
    case blur
    /// Offscreen renders such as snapshots: the smoke alone. The window server draws the live materials, so an
    /// offscreen render shows layout and translucency, never the blur.
    case smokeOnly
    /// Reduce Transparency: opaque black, as before the material.
    case solid

    static func choose(live: Bool, reduceTransparency: Bool, glassAvailable: Bool) -> NotchMaterial {
        if reduceTransparency { return .solid }
        guard live else { return .smokeOnly }
        return glassAvailable ? .glass : .blur
    }

    static var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// The dark layer over the material, and the edge. Opaque beside the hardware notch, so an open shape meets the notch
/// in black, then translucent enough to let the desktop's light through while white text keeps its contrast.
struct NotchSmoke: Equatable {
    struct Stop: Equatable {
        var opacity: Double
        var location: CGFloat
    }

    /// Opacity just below the notch band (or at the top without a notch), and at the bottom edge.
    var top: Double
    var bottom: Double
    /// The edge's white, at the top and the bottom. Only a hint: the material draws its own rim.
    var edgeTop: Double
    var edgeBottom: Double
    var edgeWidth: CGFloat

    /// Points over which the opaque notch band fades into the body.
    static let bandFade: CGFloat = 18

    /// Increase Contrast only darkens the smoke and firms the edge. It never lightens it, so with Reduce Transparency
    /// as well the surface stays opaque (`.solid` draws no material behind the smoke).
    static func make(_ material: NotchMaterial, increaseContrast: Bool) -> NotchSmoke {
        var smoke: NotchSmoke
        switch material {
        case .solid: smoke = NotchSmoke(top: 1, bottom: 1, edgeTop: 0.08, edgeBottom: 0.08, edgeWidth: 0.5)
        case .glass: smoke = NotchSmoke(top: 0.78, bottom: 0.64, edgeTop: 0.12, edgeBottom: 0.03, edgeWidth: 0.5)
        case .blur, .smokeOnly: smoke = NotchSmoke(top: 0.8, bottom: 0.68, edgeTop: 0.14, edgeBottom: 0.05, edgeWidth: 0.5)
        }
        guard increaseContrast else { return smoke }
        smoke.top = max(smoke.top, 0.94); smoke.bottom = max(smoke.bottom, 0.9)
        smoke.edgeTop = max(smoke.edgeTop, 0.34); smoke.edgeBottom = max(smoke.edgeBottom, 0.34); smoke.edgeWidth = 1
        return smoke
    }

    /// Black over a shape `height` tall whose top `band` points sit beside the notch (0 without one).
    /// `openness` 0 (closed or compact) is fully opaque; 1 is the open look; the springs move between them.
    func fill(height: CGFloat, band: CGFloat, openness: CGFloat) -> [Stop] {
        let open = Double(min(1, max(0, openness)))
        func lift(_ value: Double) -> Double { 1 - (1 - value) * open }
        return Self.banded(height: height, band: band, inBand: 1, top: lift(top), bottom: lift(bottom))
    }

    /// The edge's white. Beside the notch it is clear, so no bright line runs along the menu bar or the notch.
    func edge(height: CGFloat, band: CGFloat) -> [Stop] {
        Self.banded(height: height, band: band, inBand: 0, top: edgeTop, bottom: edgeBottom)
    }

    /// `inBand` beside the notch, fading over `bandFade` points to `top`, then to `bottom` at the lower edge.
    /// A shape that ends inside the band or its fade (as it grows or retracts) stops part way, so the band holds.
    private static func banded(height: CGFloat, band: CGFloat, inBand: Double, top: Double, bottom: Double) -> [Stop] {
        guard band > 0 else { return [Stop(opacity: top, location: 0), Stop(opacity: bottom, location: 1)] }
        guard height > band else { return [Stop(opacity: inBand, location: 0), Stop(opacity: inBand, location: 1)] }
        let solid = band / height
        guard height > band + bandFade else {
            let reached = Double((height - band) / bandFade)
            return [Stop(opacity: inBand, location: 0), Stop(opacity: inBand, location: solid),
                    Stop(opacity: inBand + (top - inBand) * reached, location: 1)]
        }
        return [Stop(opacity: inBand, location: 0), Stop(opacity: inBand, location: solid),
                Stop(opacity: top, location: (band + bandFade) / height), Stop(opacity: bottom, location: 1)]
    }
}

/// False in offscreen renders, where window-server materials and animations cannot draw.
private struct NotchLiveSurfaceKey: EnvironmentKey { static let defaultValue = true }

/// Snapshot demos only: draw as if Reduce Transparency or Increase Contrast were on. Nil follows the system, which
/// SwiftUI does not let a view set.
struct NotchAccessibilityOverride: Equatable {
    var reduceTransparency: Bool?
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

/// The island's surface at its animated outline, back to front: a soft shadow outside the outline only, the
/// material, the smoke, and a faint edge. Text and controls sit above it, unclipped by any material.
/// It takes no pointer input; the island's content shape and the panel's outline test do that.
struct NotchSurface: View {
    let shape: NotchIslandShape
    /// The shape's animated height, notch included.
    let height: CGFloat
    /// The notch's height, or 0 on a screen without one.
    let band: CGFloat
    let openness: CGFloat
    /// The outline's top flares reach past the island's frame. Each layer overhangs the frame by this much before it
    /// is cut to the outline, so the flares keep their curve into the menu bar. A `Shape` fill drew there by itself.
    static let overhang: CGFloat = 16
    @Environment(\.notchLiveSurface) private var live
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.notchAccessibilityOverride) private var override
    @Environment(\.notchIncreaseContrast) private var increaseContrast

    var body: some View {
        let material = NotchMaterial.choose(live: live, reduceTransparency: override.reduceTransparency ?? reduceTransparency,
                                            glassAvailable: NotchMaterial.glassAvailable)
        let smoke = NotchSmoke.make(material, increaseContrast: increaseContrast)
        ZStack(alignment: .top) {
            depth.opacity(Double(openness))
            if openness > 0.001 { backdrop(material) }
            gradient(smoke.fill(height: height, band: band, openness: openness), color: .black, extra: 0)
                .clipShape(shape)
            gradient(smoke.edge(height: height, band: band), color: .white, extra: smoke.edgeWidth)
                .mask { shape.stroke(lineWidth: smoke.edgeWidth) }
                .opacity(Double(openness))
        }
        .allowsHitTesting(false)
    }

    /// A vertical gradient over the shape's height, top-aligned in the island's canvas and overhanging its sides.
    private func gradient(_ stops: [NotchSmoke.Stop], color: Color, extra: CGFloat) -> some View {
        LinearGradient(stops: stops.map { Gradient.Stop(color: color.opacity($0.opacity), location: $0.location) },
                       startPoint: .top, endPoint: .bottom)
            .frame(height: max(0, height + extra))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, -Self.overhang)
    }

    /// The shadow of the open shape, cut away inside it so the material stays translucent. Rasterised on the GPU;
    /// the margin keeps the shadow and the top flare inside the layer.
    private var depth: some View {
        ZStack {
            shape.fill(Color.black).shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            shape.fill(Color.black).blendMode(.destinationOut)
        }
        .compositingGroup()
        .padding(32).drawingGroup().padding(-32)
    }

    @ViewBuilder private func backdrop(_ material: NotchMaterial) -> some View {
        switch material {
        case .glass:
            if #available(macOS 26, *) { Color.clear.padding(.horizontal, -Self.overhang).glassEffect(.regular, in: shape) }
        case .blur:
            NotchBackdropBlur(shape: shape).padding(.horizontal, -Self.overhang)
        case .smokeOnly, .solid:
            EmptyView()
        }
    }
}

/// macOS 14 and 15: the dark HUD material blurring what is behind the panel, masked to the island's outline on
/// every frame of its springs. It passes the pointer through to the island's controls.
private struct NotchBackdropBlur: NSViewRepresentable {
    let shape: NotchIslandShape

    func makeNSView(context: Context) -> BlurView { BlurView() }
    func updateNSView(_ view: BlurView, context: Context) { view.outline = shape }

    final class BlurView: NSVisualEffectView {
        private let outlineMask = CAShapeLayer()
        var outline: NotchIslandShape? { didSet { updateMask() } }

        init() {
            super.init(frame: .zero)
            material = .hudWindow
            blendingMode = .behindWindow
            state = .active
            appearance = NSAppearance(named: .darkAqua)
            wantsLayer = true
            layer?.mask = outlineMask
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Top-left origin, as in SwiftUI, so the outline's path needs no flip.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); updateMask() }

        private func updateMask() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outlineMask.frame = bounds
            outlineMask.path = outline?.path(in: bounds).cgPath
            CATransaction.commit()
        }
    }
}
