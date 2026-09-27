import SwiftUI

/// The automation's symbol on a tinted disc. Bounces on arrival; pulses while it needs the user.
struct NotchIcon: View {
    let p: NotchPresentation
    let diameter: CGFloat
    let reduceMotion: Bool
    @State private var arrived = 0

    var body: some View {
        let tint = NotchStyle.tint(p.phase)
        Image(systemName: p.symbol)
            .font(.system(size: diameter * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
            .symbolEffect(.bounce, value: reduceMotion ? 0 : arrived)
            .symbolEffect(.pulse, options: .repeating, isActive: p.wantsAttention && !reduceMotion)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint.opacity(0.18)))
            .overlay(Circle().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
            .onAppear { arrived += 1 }
            .accessibilityHidden(true)
    }
}

/// A thin ring. With a value it fills; without one it spins a short arc.
struct NotchProgressRing: View {
    let progress: Double?
    let tint: Color
    let size: CGFloat
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: 2.5)
            if let progress {
                Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else if reduceMotion {
                arc(angle: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    arc(angle: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }

    private func arc(angle: Double) -> some View {
        Circle().trim(from: 0, to: 0.28)
            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(angle - 90))
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
                    Capsule().fill(tint).frame(width: max(4, proxy.size.width * min(1, max(0, value))))
                        .animation(.easeOut(duration: 0.3), value: value)
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Right-hand status: ring and elapsed time while running, a tone label otherwise, and a "+N" stack badge.
struct NotchStatus: View {
    let p: NotchPresentation
    let reduceMotion: Bool
    /// Off where the tone label already shows elsewhere.
    var showsLabel = true
    /// Off where the stack count already shows elsewhere.
    var showsBadge = true

    var body: some View {
        let tint = NotchStyle.tint(p.phase)
        HStack(spacing: 6) {
            if showsBadge && p.stackCount > 1 {
                Text("+\(p.stackCount - 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(Capsule().fill(tint))
                    .accessibilityLabel("\(p.stackCount) alerts")
            }
            if p.phase == .running {
                elapsed.foregroundStyle(.white.opacity(0.85))
                NotchProgressRing(progress: p.progress, tint: tint, size: 16, reduceMotion: reduceMotion)
            } else if showsLabel {
                Text(NotchStyle.statusText(p))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder private var elapsed: some View {
        if let start = p.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(start)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(reduceMotion ? nil : .snappy, value: Int(context.date.timeIntervalSince(start)))
            }
            .accessibilityLabel("Elapsed")
        } else {
            Text(NotchStyle.statusText(p)).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct NotchButtonStyle: ButtonStyle {
    let primary: Bool
    let tint: Color
    var fill = false
    var destructive = false

    init(primary: Bool, tint: Color, fill: Bool = false, destructive: Bool = false) {
        self.primary = primary; self.tint = tint; self.fill = fill; self.destructive = destructive
    }

    init(_ action: NotchAlert.Action, tint: Color, fill: Bool = false) {
        self.init(primary: action.primary, tint: tint, fill: fill, destructive: action.role == .destructive)
    }

    func makeBody(configuration: Configuration) -> some View {
        NotchButtonBody(label: configuration.label, pressed: configuration.isPressed, primary: primary, tint: tint, fill: fill,
                        destructive: destructive)
    }
}

private struct NotchButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let primary: Bool
    let tint: Color
    let fill: Bool
    let destructive: Bool
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: NotchStyle.buttonHeight)
            .background(Capsule().fill(primary ? tint : Color.white.opacity(hovering ? 0.20 : 0.13)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(primary ? 0.25 : 0.06), lineWidth: 0.5))
            .foregroundStyle(primary ? Color.black.opacity(0.88) : destructive ? NotchStyle.tint(.failure) : Color.white)
            .brightness(primary && hovering ? 0.06 : 0)
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: pressed)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}
