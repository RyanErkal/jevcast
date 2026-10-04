import AppKit
import SwiftUI

/// The automation's symbol. With an accent it fills a disc in that colour behind a white glyph, and a state that needs
/// a word (question, review, failure, success) adds a small badge in the state's colour. Without an accent the glyph
/// carries the state tint on a quiet disc, as before.
struct NotchIcon: View {
    let p: NotchPresentation
    let diameter: CGFloat
    let reduceMotion: Bool
    var showsBadge = true
    @State private var arrived = 0

    var body: some View {
        // One quiet cue on arrival for alerts that need the user. Nothing repeats.
        NotchGlyph(symbol: p.symbol, accent: p.accent, phase: p.phase, diameter: diameter,
                   pulse: reduceMotion || !p.wantsAttention ? 0 : arrived)
            .overlay(alignment: .bottomTrailing) {
                if showsBadge, p.accent != nil, let badge = NotchBadge.symbol(p.phase) {
                    NotchBadge(symbol: badge, tint: NotchStyle.tint(p.phase), diameter: max(12, diameter * 0.42))
                        .offset(x: diameter * 0.08, y: diameter * 0.08)
                }
            }
            .onAppear { arrived += 1 }
            .accessibilityHidden(true)
    }
}

/// One symbol in its disc: the accent fill with a white glyph, or the state-tinted glyph on a quiet fill.
struct NotchGlyph: View {
    let symbol: String
    let accent: String?
    let phase: NotchPresentation.Phase
    let diameter: CGFloat
    var pulse = 0

    var body: some View {
        let fill = NotchStyle.accent(accent)
        Image(systemName: symbol)
            .font(.system(size: diameter * (fill == nil ? 0.44 : 0.48), weight: fill == nil ? .medium : .semibold))
            .foregroundStyle(fill == nil ? NotchStyle.tint(phase) : .white)
            .symbolRenderingMode(.monochrome)
            .symbolEffect(.pulse, options: .nonRepeating, value: pulse)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill.map { AnyShapeStyle($0.gradient) } ?? AnyShapeStyle(Color.white.opacity(0.1))))
    }
}

/// The small state mark on an accented icon. A black ring separates it from any accent, red included.
struct NotchBadge: View {
    let symbol: String
    let tint: Color
    let diameter: CGFloat

    static func symbol(_ phase: NotchPresentation.Phase) -> String? {
        switch phase {
        case .question: return "questionmark"
        case .approval: return "hand.raised.fill"
        case .review: return "eye.fill"
        case .failure: return "exclamationmark"
        case .success: return "checkmark"
        case .running, .info: return nil
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.52, weight: .heavy))
            .foregroundStyle(.black)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint))
            .overlay(Circle().strokeBorder(Color.black, lineWidth: 2).padding(-2))
    }
}

/// Up to `NotchPresentation.maxIdentities` icons of automations running together, overlapped, in a fixed order.
/// They never cycle; the count beside the ring gives the total.
struct NotchIconStack: View {
    let identities: [NotchPresentation.Identity]
    let diameter: CGFloat

    var body: some View {
        HStack(spacing: -diameter * 0.4) {
            ForEach(Array(identities.enumerated()), id: \.offset) { index, look in
                NotchGlyph(symbol: look.symbol, accent: look.accent, phase: .running, diameter: diameter)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5).padding(-1.5))
                    .zIndex(Double(identities.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A thin ring. With a value it fills; without one it turns a short arc. The turning is a Core Animation layer in the
/// window server, so a pill left up through a long run costs the app no frames. Offscreen renders and Reduce Motion
/// draw the arc still.
struct NotchProgressRing: View {
    let progress: Double?
    let tint: Color
    let size: CGFloat
    let reduceMotion: Bool
    @Environment(\.notchLiveSurface) private var live
    private let line: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: line)
            if let progress {
                Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else if reduceMotion || !live {
                Circle().trim(from: 0, to: NotchSpinner.arc)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                NotchSpinner(tint: NSColor(tint), line: line)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

/// The turning arc of an indeterminate ring: a shape layer with a repeating rotation, run by the window server.
/// It takes no pointer input, so a click on the pill reaches the pill.
struct NotchSpinner: NSViewRepresentable {
    /// The arc's share of the circle.
    static let arc: CGFloat = 0.25
    /// Seconds per turn.
    static let period: CFTimeInterval = 1.4

    let tint: NSColor
    let line: CGFloat

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }
    func updateNSView(_ view: SpinnerView, context: Context) { view.style(tint: tint, line: line) }

    final class SpinnerView: NSView {
        private let shape = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            shape.fillColor = nil
            shape.lineCap = .round
            shape.strokeStart = 0
            shape.strokeEnd = NotchSpinner.arc
            layer?.addSublayer(shape)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func style(tint: NSColor, line: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectiveAppearance.performAsCurrentDrawingAppearance { shape.strokeColor = tint.cgColor }
            shape.lineWidth = line
            CATransaction.commit()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = bounds
            let inset = shape.lineWidth / 2
            // Starts at twelve o'clock, as the still arc does.
            let circle = CGMutablePath()
            circle.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(0, min(bounds.width, bounds.height) / 2 - inset),
                          startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: !shape.contentsAreFlipped())
            shape.path = circle
            CATransaction.commit()
            spin()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            spin()
        }

        /// Clockwise on screen, whichever way the layer's geometry runs.
        private func spin() {
            guard window != nil, shape.animation(forKey: "spin") == nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = (shape.contentsAreFlipped() ? 1 : -1) * 2 * Double.pi
            turn.duration = NotchSpinner.period
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            shape.add(turn, forKey: "spin")
        }
    }
}

/// A thin determinate bar, drawn in SwiftUI so it renders offscreen and costs nothing.
struct NotchProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        Capsule().fill(Color.white.opacity(0.12))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: max(3, proxy.size.width * min(1, max(0, value))))
                        .animation(.easeOut(duration: 0.3), value: value)
                }
            }
            .frame(height: 3)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// The one status mark at the right: a ring while running (or a retry mark while a retry waits), a finished run's
/// outcome in the pill, the number of automations running or finished together, or a stack's "+N". No elapsed time:
/// the open running card shows that once.
struct NotchStatus: View {
    let p: NotchPresentation
    let reduceMotion: Bool
    /// Off where the stack count already shows elsewhere.
    var showsBadge = true
    /// The pill draws a finished run's outcome where its ring was. Cards show the outcome on the icon instead.
    var showsOutcome = false
    var ringSize: CGFloat = 14

    /// The outcome mark: done, failed, or needs review.
    static func outcome(_ phase: NotchPresentation.Phase) -> (symbol: String, label: String)? {
        switch phase {
        case .success: return ("checkmark.circle.fill", "Done")
        case .failure: return ("exclamationmark.circle.fill", "Failed")
        case .review: return ("eye.circle.fill", "Needs review")
        case .running, .question, .approval, .info: return nil
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if p.isPillStack {
                Text("\(p.stackCount)")
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityLabel("\(p.stackCount) " + (p.phase == .running ? "running" : "finished"))
            } else if showsBadge && p.stackCount > 1 {
                Text("+\(p.stackCount - 1)")
                    .accessibilityLabel("\(p.stackCount) alerts")
            }
            if p.phase == .running {
                Group {
                    if p.retry != nil {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: ringSize * 0.8, weight: .semibold))
                            .frame(width: ringSize, height: ringSize)
                            .accessibilityLabel("Waiting to retry")
                    } else {
                        NotchProgressRing(progress: p.progress, tint: NotchStyle.ring, size: ringSize, reduceMotion: reduceMotion)
                    }
                }
                .transition(.opacity)
            } else if showsOutcome, p.minimized, let mark = Self.outcome(p.phase) {
                // The ring gives way to the mark: it grows in, in the outcome's colour, where the ring turned.
                Image(systemName: mark.symbol)
                    .font(.system(size: ringSize + 2, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(NotchStyle.tint(p.phase))
                    .frame(width: ringSize + 2, height: ringSize + 2)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                    .accessibilityLabel(mark.label)
            }
        }
        .font(NotchStyle.Font.meta)
        .foregroundStyle(NotchStyle.secondaryText)
        .lineLimit(1)
        .fixedSize()
    }
}

/// The open running card's quiet line: the one elapsed time and the last success, as far as each is known.
struct NotchRunningMeta: View {
    let p: NotchPresentation

    var body: some View {
        Group {
            if p.startedAt != nil {
                TimelineView(.periodic(from: p.startedAt ?? Date(), by: 1)) { context in label(now: context.date) }
            } else {
                label(now: Date())
            }
        }
        .font(NotchStyle.Font.meta).foregroundStyle(NotchStyle.metaText)
        .lineLimit(1).truncationMode(.tail)
    }

    private func label(now: Date) -> some View {
        Text(Self.line(p, now: now)).accessibilityLabel(Self.line(p, now: now, spoken: true))
    }

    static func line(_ p: NotchPresentation, now: Date, spoken: Bool = false) -> String {
        var parts: [String] = []
        if let start = p.startedAt { parts.append(NotchStyle.clock(now.timeIntervalSince(start)) + (spoken ? " elapsed" : "")) }
        if let last = p.lastSuccess { parts.append("Last success " + NotchStyle.ago(last, now: now)) }
        return parts.joined(separator: " · ")
    }
}

/// Capsule buttons. Primary is white with black text, the one solid control; a destructive primary uses the failure
/// accent. Secondary is a light fill with a hairline edge, so it sits in the material; a destructive secondary has
/// accent text. Increase Contrast makes the fill and edge stronger.
struct NotchButtonStyle: ButtonStyle {
    let primary: Bool
    var fill = false
    var destructive = false

    init(primary: Bool, fill: Bool = false, destructive: Bool = false) {
        self.primary = primary; self.fill = fill; self.destructive = destructive
    }

    init(_ action: NotchAlert.Action, fill: Bool = false) {
        self.init(primary: action.primary, fill: fill, destructive: action.role == .destructive)
    }

    func makeBody(configuration: Configuration) -> some View {
        NotchButtonBody(label: configuration.label, pressed: configuration.isPressed, primary: primary, fill: fill,
                        destructive: destructive)
    }
}

private struct NotchButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let primary: Bool
    let fill: Bool
    let destructive: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.notchIncreaseContrast) private var increased

    var body: some View {
        label
            .font(NotchStyle.Font.button)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: NotchStyle.buttonMinWidth, maxWidth: fill ? .infinity : nil)
            .frame(height: NotchStyle.buttonHeight)
            .background(Capsule().fill(background))
            .overlay {
                if !primary { Capsule().strokeBorder(Color.white.opacity(NotchStyle.controlEdge(increased: increased)), lineWidth: 0.5) }
            }
            .foregroundStyle(foreground)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }

    private var background: Color {
        if primary { return destructive ? NotchStyle.destructive : Color.white.opacity(hovering ? 0.88 : 1) }
        return Color.white.opacity(NotchStyle.controlFill(increased: increased, hovering: hovering, pressed: pressed))
    }

    private var foreground: Color {
        if primary { return destructive ? .white : .black }
        return destructive ? NotchStyle.destructive : .white
    }
}

/// A circular icon button: the overflow menu and Show less. Hover lightens it; a press dips it, like the capsules.
struct NotchIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(NotchIconButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct NotchIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NotchIconButtonBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct NotchIconButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovering = false
    @Environment(\.notchIncreaseContrast) private var increased

    var body: some View {
        label
            .frame(width: NotchStyle.buttonHeight, height: NotchStyle.buttonHeight)
            .background(Circle().fill(Color.white.opacity(NotchStyle.controlFill(increased: increased, hovering: hovering, pressed: pressed) - 0.01)))
            .overlay(Circle().strokeBorder(Color.white.opacity(NotchStyle.controlEdge(increased: increased)), lineWidth: 0.5))
            .foregroundStyle(.white.opacity(0.85))
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// The actions past the first two, in a native menu at the pointer.
@MainActor
enum NotchOverflowMenu {
    static func show(_ actions: [NotchAlert.Action], perform: @escaping (String) -> Void) {
        let menu = NSMenu()
        for item in actions {
            let entry = NSMenuItem(title: item.title, action: #selector(Target.run(_:)), keyEquivalent: "")
            let target = Target { perform(item.id) }
            entry.target = target
            entry.representedObject = target
            menu.addItem(entry)
        }
        NotchMenuGuard.ownMenuOpen = true
        defer { NotchMenuGuard.ownMenuOpen = false; NotchMenuGuard.ownMenuClosed = Date() }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run(_ sender: Any?) { action() }
    }
}
