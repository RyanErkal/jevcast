import AppKit
import SwiftUI

/// What the island's controls call. On screen these go to `NotchState`; snapshots pass no-ops.
struct NotchHandlers {
    /// An action ID, and the stack row it belongs to (nil for the alert on screen).
    var perform: (String, String?) -> Void
    var submit: (String) -> Void
    var cancel: () -> Void

    static let none = NotchHandlers(perform: { _, _ in }, submit: { _ in }, cancel: {})
}

/// The panel's root view. The controller sets `state.alert`, `state.mode`, and `state.expanded`;
/// this view draws them. On arrival the island pauses at compact for a beat, so it visibly grows out of the notch.
struct NotchAlertView: View {
    @ObservedObject var state: NotchState
    let action: (String) -> Void
    let hover: (Bool) -> Void
    @State private var staged = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let alert = state.alert {
                NotchIsland(alert: alert, geometry: state.geometry, mode: mode, replyTarget: state.replyTarget,
                            handlers: handlers)
                    .onHover(perform: hover)
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

    private var mode: NotchMode {
        guard state.expanded else { return .collapsed }
        if staged && !reduceMotion { return .compact }
        return NotchMode(state.mode)
    }

    private var handlers: NotchHandlers {
        let state = self.state
        let action = self.action
        return NotchHandlers(perform: { id, row in row == nil ? action(id) : state.perform(id, on: row) },
                             submit: { state.submitReply($0) },
                             cancel: { state.cancelReply() })
    }
}

/// The black island in one mode. It draws only from its inputs, so snapshots can render any state.
struct NotchIsland: View {
    let alert: NotchAlert
    let geometry: NotchGeometry
    let mode: NotchMode
    var replyTarget: String?
    var handlers: NotchHandlers = .none
    /// False in snapshots: the reply field draws as text, since offscreen rendering cannot draw a live field.
    var liveField = true
    /// Text shown in the reply field when it opens. Snapshots use it.
    var draft = ""
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var p: NotchPresentation { alert.presentation }
    private var tint: Color { NotchStyle.tint(p.phase) }
    private var hasNotch: Bool { geometry.hasNotch }
    private var shape: NotchShape {
        let radius = NotchStyle.bottomRadius(mode, hasNotch: hasNotch)
        return NotchShape(bottomRadius: radius, topRadius: hasNotch ? 0 : radius, topFlare: hasNotch ? (mode.isOpen ? 10 : 7) : 0)
    }

    var body: some View {
        let size = NotchStyle.size(mode, alert, geometry)
        ZStack(alignment: .top) {
            NotchSurface(shape: shape, tint: tint, mode: mode, reduceTransparency: reduceTransparency)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .scaleEffect(x: 1, y: !hasNotch && mode == .collapsed ? 0.6 : 1, anchor: .top)
        .opacity(!hasNotch && mode == .collapsed ? 0 : 1)
        .offset(y: hasNotch ? 0 : (mode == .collapsed ? -NotchGeometry.pillBody : NotchGeometry.topGap))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(p.title). \(p.message)\(p.detail.map { ". " + $0 } ?? "")")
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .collapsed: Color.clear
        case .compact: compact.transition(.opacity)
        case .card: card.transition(opening)
        case .detail:
            Group { if alert.isStack { list } else { runningDetail } }.transition(opening)
        case .reply: reply.transition(opening)
        }
    }

    private var opening: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)), removal: .opacity)
    }

    private func perform(_ id: String, row: String? = nil) { handlers.perform(id, row) }

    // MARK: Compact: icon left of the notch, status right of it. A click opens the detail.

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
        .frame(height: hasNotch ? geometry.notchHeight : NotchGeometry.pillBody)
        .contentShape(Rectangle())
        .onTapGesture { if p.phase == .running { perform(NotchAlert.expandAction) } }
        .accessibilityAddTraits(p.phase == .running ? .isButton : [])
        .accessibilityAction(named: "Show details") { perform(NotchAlert.expandAction) }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasNotch { band(collapse: false) }
            header(p, trailing: headerTrailing)
            if !p.isBrief {
                if !p.choices.isEmpty {
                    HStack(spacing: 6) { ForEach(p.choices) { button($0, fill: true) } }
                }
                footer
            }
        }
        .modifier(IslandPadding(hasNotch: hasNotch))
    }

    @ViewBuilder private var headerTrailing: some View {
        if p.isBrief, let only = p.visibleActions.first {
            button(only)
        } else if !hasNotch {
            NotchStatus(p: p, reduceMotion: reduceMotion, showsLabel: p.phase == .running)
        }
    }

    /// The strip beside the notch: tone label left, live status right. In detail it also holds the collapse control.
    private func band(collapse: Bool) -> some View {
        HStack(spacing: 0) {
            Text(bandLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.8)
                .foregroundStyle(tint)
                .lineLimit(1).fixedSize()
            Spacer(minLength: geometry.notchWidth + 8)
            HStack(spacing: 8) {
                NotchStatus(p: p, reduceMotion: reduceMotion, showsLabel: false, showsBadge: !alert.isStack)
                    .matchedGeometryEffect(id: "status", in: space)
                if collapse { collapseButton }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: geometry.notchHeight)
        .padding(.bottom, -2)
    }

    private var bandLabel: String {
        alert.isStack ? "\(alert.stackCount) ALERTS" : NotchStyle.statusText(p).uppercased()
    }

    private var collapseButton: some View {
        Button { perform(NotchAlert.collapseAction) } label: {
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .foregroundStyle(.white.opacity(0.85))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show less")
    }

    private func header(_ p: NotchPresentation, lines: Int = 1, trailing: some View = EmptyView()) -> some View {
        HStack(alignment: .center, spacing: 11) {
            NotchIcon(p: p, diameter: 32, reduceMotion: reduceMotion)
                .matchedGeometryEffect(id: "icon", in: space)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "title", in: space, properties: .position)
                Text(subtitle(p))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.62))
                    .lineLimit(lines)
            }
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }

    /// The capsule left of the buttons has room only beside two buttons or fewer.
    private func detailInFooter(_ p: NotchPresentation) -> Bool { p.visibleActions.count <= 2 && p.phase != .running }

    /// The message, with the detail after it when the footer has no room for the detail.
    private func subtitle(_ p: NotchPresentation) -> String {
        guard let detail = p.detail, mode != .detail, !detailInFooter(p) || mode == .reply || p.isBrief else { return p.message }
        return p.message + " · " + detail
    }

    private var footer: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 4)
            ForEach(p.visibleActions) { button($0) }
        }
    }

    /// Left of the buttons: counts or a reason, a progress bar, or nothing.
    @ViewBuilder private var leading: some View {
        if let detail = p.detail, detailInFooter(p) {
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
            NotchProgressBar(value: value, tint: tint).frame(maxWidth: 150)
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

    private func button(_ item: NotchAlert.Action, fill: Bool = false, row: String? = nil, tint: Color? = nil) -> some View {
        Button(item.title) { perform(item.id, row: row) }
            .buttonStyle(NotchButtonStyle(item, tint: tint ?? self.tint, fill: fill))
            .accessibilityHint(p.title)
    }

    // MARK: Detail: a running automation's latest activity

    private var runningDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasNotch { band(collapse: true) }
            header(p, trailing: Group { if !hasNotch { collapseButton } })
            Text(p.detail ?? "No activity yet.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(p.detail == nil ? 0.45 : 0.8))
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            footer
        }
        .modifier(IslandPadding(hasNotch: hasNotch))
    }

    // MARK: Detail: a stack as a list

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasNotch { band(collapse: true) }
            HStack(spacing: 10) {
                Text(p.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if alert.stackCount > NotchGeometry.maxRows {
                    Text("\(NotchGeometry.maxRows) of \(alert.stackCount)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 4)
                if let later = p.actions.first(where: { $0.id == "later" }) {
                    Button("All later") { perform(later.id) }
                        .buttonStyle(NotchButtonStyle(primary: false, tint: tint))
                }
                if !hasNotch { collapseButton }
            }
            .frame(height: 28)
            VStack(spacing: 8) {
                ForEach(alert.stack.prefix(NotchGeometry.maxRows)) { row($0) }
            }
        }
        .modifier(IslandPadding(hasNotch: hasNotch, bottom: NotchGeometry.listBottom))
    }

    private func row(_ member: NotchAlert) -> some View {
        let rp = member.presentation
        let rowTint = NotchStyle.tint(rp.phase)
        return HStack(spacing: 10) {
            NotchIcon(p: rp, diameter: 24, reduceMotion: reduceMotion)
            VStack(alignment: .leading, spacing: 0) {
                Text(rp.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text(rp.phase == .running || rp.phase == .approval ? rp.detail ?? rp.message
                     : rp.detail.map { rp.message + " · " + $0 } ?? rp.message)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.58))
            }
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(rp.rowActions) { button($0, row: member.id, tint: rowTint) }
        }
        .padding(.leading, 7).padding(.trailing, 6)
        .frame(height: NotchGeometry.rowHeight - 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.055)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rp.title). \(rp.message)")
    }

    // MARK: Reply

    /// The alert the reply answers: the one on screen, or a row of the stack.
    private var replyAlert: NotchAlert {
        guard let replyTarget, replyTarget != alert.id else { return alert }
        return alert.stack.first { $0.id == replyTarget } ?? alert
    }

    private var reply: some View {
        let target = replyAlert.presentation
        return VStack(alignment: .leading, spacing: 10) {
            if hasNotch { band(collapse: false) }
            header(target, lines: 2)
            NotchReplyRow(live: liveField, initial: draft, tint: NotchStyle.tint(target.phase),
                          submit: handlers.submit, cancel: handlers.cancel)
        }
        .modifier(IslandPadding(hasNotch: hasNotch))
    }
}

/// Inside the island: under the notch band, or 10 from the top without a notch.
private struct IslandPadding: ViewModifier {
    let hasNotch: Bool
    var bottom: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(.top, hasNotch ? 0 : 10)
            .padding(.horizontal, 16)
            .padding(.bottom, bottom)
    }
}

/// The answer field with Cancel and Send. Return sends; Escape cancels.
private struct NotchReplyRow: View {
    let live: Bool
    let initial: String
    let tint: Color
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 6) {
            Group {
                if live {
                    TextField("Type an answer", text: $text)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { if !empty { submit(text) } }
                        .onExitCommand(perform: cancel)
                } else {
                    Text(text.isEmpty ? "Type an answer" : text)
                        .foregroundStyle(.white.opacity(text.isEmpty ? 0.4 : 1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(tint.opacity(0.55), lineWidth: 1))
            Button("Cancel", action: cancel)
                .buttonStyle(NotchButtonStyle(primary: false, tint: tint))
            Button("Send") { submit(text) }
                .buttonStyle(NotchButtonStyle(primary: true, tint: tint))
                .disabled(empty)
                .opacity(empty ? 0.5 : 1)
        }
        .onAppear {
            text = initial
            if live { DispatchQueue.main.async { focused = true } }
        }
    }
}
