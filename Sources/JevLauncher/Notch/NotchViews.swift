import AppKit
import SwiftUI

/// The panel's root view. The controller sets `state.expanded`; this view turns that into
/// collapsed → compact → expanded, and keeps a running alert compact until the pointer is over it.
struct NotchAlertView: View {
    @ObservedObject var state: NotchState
    let action: (String) -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false
    /// Arrival pauses at compact for a beat, so the island visibly grows out of the notch.
    @State private var staged = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let alert = state.alert {
                let p = alert.presentation
                NotchIsland(p: p, geometry: state.geometry, mode: mode(p), action: action)
                    .onHover { inside in
                        withAnimation(NotchStyle.morph(reduceMotion: reduceMotion)) { hovering = inside }
                        hover(inside)
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: state.expanded) { _, open in
            guard open else { staged = true; return }
            if reduceMotion { staged = false; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(NotchStyle.morph(reduceMotion: false)) { staged = false }
            }
        }
    }

    private func mode(_ p: NotchPresentation) -> NotchMode {
        guard state.expanded else { return .collapsed }
        if hovering { return .expanded }
        if staged && !reduceMotion { return .compact }
        return p.phase == .running ? .compact : .expanded
    }
}

/// The black island at one mode. Pure: it draws from its inputs, so snapshots can render any state.
struct NotchIsland: View {
    let p: NotchPresentation
    let geometry: NotchGeometry
    let mode: NotchMode
    let action: (String) -> Void
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var hasNotch: Bool { geometry.hasNotch }
    private var shape: NotchShape {
        let radius = NotchStyle.bottomRadius(mode, hasNotch: hasNotch)
        return NotchShape(bottomRadius: radius, topRadius: hasNotch ? 0 : radius, topFlare: hasNotch ? (mode == .expanded ? 10 : 7) : 0)
    }

    var body: some View {
        let size = NotchStyle.size(mode, p, geometry)
        ZStack(alignment: .top) {
            NotchSurface(shape: shape, tint: NotchStyle.tint(p.phase), mode: mode, reduceTransparency: reduceTransparency)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(x: 1, y: !hasNotch && mode == .collapsed ? 0.6 : 1, anchor: .top)
        .opacity(!hasNotch && mode == .collapsed ? 0 : 1)
        .offset(y: hasNotch ? 0 : (mode == .collapsed ? -NotchStyle.pillHeight : NotchStyle.pillTopGap))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(p.title). \(p.message)\(p.detail.map { ". " + $0 } ?? "")")
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .collapsed: Color.clear
        case .compact: compact.transition(.opacity)
        case .expanded: expanded.transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                                                        removal: .opacity))
        }
    }

    // MARK: Compact: icon left of the notch, status right of it.

    private var compact: some View {
        HStack(spacing: 0) {
            NotchIcon(p: p, diameter: 22, reduceMotion: reduceMotion)
                .matchedGeometryEffect(id: "icon", in: space)
                .padding(.leading, hasNotch ? 14 : 8)
            if hasNotch {
                Spacer(minLength: geometry.notchWidth)
            } else {
                Text(p.title)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
                    .matchedGeometryEffect(id: "title", in: space, properties: .position)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            NotchStatus(p: p, reduceMotion: reduceMotion)
                .matchedGeometryEffect(id: "status", in: space)
                .padding(.trailing, hasNotch ? 14 : 12)
        }
        .frame(height: hasNotch ? geometry.notchHeight : NotchStyle.pillHeight)
    }

    // MARK: Expanded card

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasNotch { band }
            header
            if !p.isBrief { footer }
        }
        .padding(.top, hasNotch ? 0 : 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// The strip beside the notch: tone label left, live status right, as in compact mode.
    private var band: some View {
        HStack(spacing: 0) {
            Text(NotchStyle.statusText(p).uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.8)
                .foregroundStyle(NotchStyle.tint(p.phase))
                .lineLimit(1).fixedSize()
            Spacer(minLength: geometry.notchWidth + 8)
            NotchStatus(p: p, reduceMotion: reduceMotion, showsLabel: false)
                .matchedGeometryEffect(id: "status", in: space)
        }
        .padding(.horizontal, 6)
        .frame(height: geometry.notchHeight)
        .padding(.bottom, -2)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            NotchIcon(p: p, diameter: 32, reduceMotion: reduceMotion)
                .matchedGeometryEffect(id: "icon", in: space)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .matchedGeometryEffect(id: "title", in: space, properties: .position)
                Text(p.message)
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            if p.isBrief, let only = p.visibleActions.first {
                button(only, fill: false)
            } else if !hasNotch {
                NotchStatus(p: p, reduceMotion: reduceMotion, showsLabel: p.phase == .running)
                    .matchedGeometryEffect(id: "status", in: space)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if p.phase == .question {
            // Choices get equal width so none looks preferred beyond the primary tint.
            HStack(spacing: 6) {
                ForEach(p.visibleActions, id: \.id) { item in button(item, fill: true) }
            }
        } else {
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 4)
                ForEach(p.visibleActions, id: \.id) { item in button(item, fill: false) }
            }
        }
    }

    /// Left of the buttons: counts, a progress bar, or nothing.
    @ViewBuilder private var leading: some View {
        if let detail = p.detail {
            HStack(spacing: 5) {
                Image(systemName: detailSymbol).font(.system(size: 10, weight: .semibold))
                Text(detail).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 9)
            .frame(height: NotchStyle.buttonHeight)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .layoutPriority(-1)
        } else if p.phase == .running, let value = p.progress {
            NotchProgressBar(value: value, tint: NotchStyle.tint(p.phase)).frame(maxWidth: 150)
        }
    }

    private var detailSymbol: String {
        switch p.phase {
        case .approval: return "tray.full"
        case .failure: return "exclamationmark.triangle"
        case .running: return "clock"
        default: return "info.circle"
        }
    }

    private func button(_ item: NotchAlert.Action, fill: Bool) -> some View {
        Button(item.title) { action(item.id) }
            .buttonStyle(NotchButtonStyle(primary: item.primary, tint: NotchStyle.tint(p.phase), fill: fill))
            .accessibilityHint(p.title)
    }
}
