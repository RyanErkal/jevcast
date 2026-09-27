import AppKit
import SwiftUI

/// The automation's symbol in a plain circle. Only the glyph carries the accent colour.
struct NotchIcon: View {
    let p: NotchPresentation
    let diameter: CGFloat
    let reduceMotion: Bool
    @State private var arrived = 0

    var body: some View {
        Image(systemName: p.symbol)
            .font(.system(size: diameter * 0.44, weight: .medium))
            .foregroundStyle(NotchStyle.tint(p.phase))
            .symbolRenderingMode(.monochrome)
            // One quiet cue on arrival for alerts that need the user. Nothing repeats.
            .symbolEffect(.pulse, options: .nonRepeating, value: reduceMotion || !p.wantsAttention ? 0 : arrived)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color.white.opacity(0.1)))
            .onAppear { arrived += 1 }
            .accessibilityHidden(true)
    }
}

/// A thin ring. With a value it fills; without one it turns a short arc.
struct NotchProgressRing: View {
    let progress: Double?
    let tint: Color
    let size: CGFloat
    let reduceMotion: Bool
    private let line: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: line)
            if let progress {
                Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else if reduceMotion {
                arc(angle: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    arc(angle: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }

    private func arc(angle: Double) -> some View {
        Circle().trim(from: 0, to: 0.25)
            .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
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

/// Grey meta at the right: elapsed time and a thin ring while running, and the stack count.
struct NotchStatus: View {
    let p: NotchPresentation
    let reduceMotion: Bool
    /// Off where the stack count already shows elsewhere.
    var showsBadge = true

    var body: some View {
        HStack(spacing: 8) {
            if showsBadge && p.stackCount > 1 {
                Text("+\(p.stackCount - 1)")
                    .accessibilityLabel("\(p.stackCount) alerts")
            }
            if p.phase == .running {
                elapsed
                NotchProgressRing(progress: p.progress, tint: NotchStyle.tint(p.phase), size: 14, reduceMotion: reduceMotion)
            }
        }
        .font(NotchStyle.Font.meta)
        .foregroundStyle(NotchStyle.secondaryText)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder private var elapsed: some View {
        if let start = p.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(start)))
                    .contentTransition(.numericText(countsDown: false))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: Int(context.date.timeIntervalSince(start)))
            }
            .accessibilityLabel("Elapsed")
        } else {
            Text(NotchStyle.statusText(p))
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Capsule buttons. Primary is white with black text; a destructive primary uses the failure accent.
/// Secondary is a quiet white fill; a destructive secondary has accent text.
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

    var body: some View {
        label
            .font(NotchStyle.Font.button)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: NotchStyle.buttonMinWidth, maxWidth: fill ? .infinity : nil)
            .frame(height: NotchStyle.buttonHeight)
            .background(Capsule().fill(background))
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
        return Color.white.opacity(hovering ? 0.18 : 0.12)
    }

    private var foreground: Color {
        if primary { return destructive ? .white : .black }
        return destructive ? NotchStyle.destructive : .white
    }
}

/// A circular icon button: the overflow menu and Show less.
struct NotchIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: NotchStyle.buttonHeight, height: NotchStyle.buttonHeight)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.18 : 0.12)))
                .foregroundStyle(.white.opacity(0.85))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
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
        defer { NotchMenuGuard.ownMenuOpen = false }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run(_ sender: Any?) { action() }
    }
}
