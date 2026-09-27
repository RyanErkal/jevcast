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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var p: NotchPresentation { alert.presentation }
    private var hasNotch: Bool { geometry.hasNotch }
    private var shape: NotchShape {
        let radius = NotchStyle.bottomRadius(mode, hasNotch: hasNotch)
        return NotchShape(bottomRadius: radius, topRadius: hasNotch ? 0 : radius, topFlare: hasNotch ? (mode.isOpen ? 10 : 7) : 0)
    }

    var body: some View {
        let size = NotchStyle.size(mode, alert, geometry)
        ZStack(alignment: .top) {
            NotchSurface(shape: shape, mode: mode)
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
        let fade = NotchStyle.contentFade(reduceMotion: reduceMotion)
        switch mode {
        case .collapsed: Color.clear
        case .compact: compact.transition(fade)
        case .card: card.transition(fade)
        case .detail:
            Group { if alert.isStack { list } else { runningDetail } }.transition(fade)
        case .reply: reply.transition(fade)
        }
    }

    private func perform(_ id: String, row: String? = nil) { handlers.perform(id, row) }

    // MARK: Compact: icon left of the notch, elapsed time and ring right of it. A click opens the detail.

    private var compact: some View {
        HStack(spacing: 8) {
            NotchIcon(p: p, diameter: 20, reduceMotion: reduceMotion)
            if hasNotch {
                Spacer(minLength: geometry.notchWidth)
            } else {
                Text(p.title)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            NotchStatus(p: p, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, hasNotch ? 12 : 8)
        .padding(.trailing, hasNotch ? 0 : 4)
        .frame(height: hasNotch ? geometry.notchHeight : NotchGeometry.pillBody)
        .contentShape(Rectangle())
        .onTapGesture { if p.phase == .running { perform(NotchAlert.expandAction) } }
        .accessibilityAddTraits(p.phase == .running ? .isButton : [])
        .accessibilityAction(named: "Show details") { perform(NotchAlert.expandAction) }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasNotch { band(collapse: false) }
            header(p, trailing: headerTrailing)
            if !p.isBrief {
                if !p.choices.isEmpty {
                    HStack(spacing: 8) { ForEach(p.choices) { button($0, fill: true) } }
                        .padding(.top, 12)
                }
                footer.padding(.top, p.choices.isEmpty ? 12 : 8)
            }
        }
        .modifier(IslandPadding(hasNotch: hasNotch))
    }

    @ViewBuilder private var headerTrailing: some View {
        if p.isBrief, let only = p.visibleActions.first {
            button(only)
        } else if !hasNotch {
            NotchStatus(p: p, reduceMotion: reduceMotion)
        }
    }

    /// The strip right of the notch: grey meta, and in detail the collapse control. Content starts 8 below it.
    private func band(collapse: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            NotchStatus(p: p, reduceMotion: reduceMotion, showsBadge: !alert.isStack)
            if collapse { collapseButton(size: 22) }
        }
        .frame(width: max(0, (geometry.width(.card) - geometry.notchWidth) / 2 - NotchStyle.padding), height: geometry.notchHeight)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.bottom, NotchGeometry.bandGap)
    }

    private func collapseButton(size: CGFloat = NotchStyle.buttonHeight) -> some View {
        NotchIconButton(symbol: "chevron.up", label: "Show less") { perform(NotchAlert.collapseAction) }
            .scaleEffect(size / NotchStyle.buttonHeight)
            .frame(width: size, height: size)
    }

    private func header(_ p: NotchPresentation, lines: Int = 1, trailing: some View = EmptyView()) -> some View {
        HStack(alignment: .center, spacing: 12) {
            NotchIcon(p: p, diameter: 32, reduceMotion: reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title)
                    .font(NotchStyle.Font.title).foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle(p))
                    .font(NotchStyle.Font.message).foregroundStyle(NotchStyle.secondaryText)
                    .lineLimit(lines)
            }
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(minHeight: 32)
    }

    /// The footer shows the detail left of the buttons, except while running, where the bar goes there.
    private func detailInFooter(_ p: NotchPresentation) -> Bool { p.phase != .running }

    /// The message, with the detail after it when the footer does not show the detail.
    private func subtitle(_ p: NotchPresentation) -> String {
        guard let detail = p.detail, mode != .detail, !detailInFooter(p) || mode == .reply || p.isBrief else { return p.message }
        return p.message + " · " + detail
    }

    private var footer: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            ForEach(p.visibleActions) { button($0) }
            if !p.overflowActions.isEmpty {
                let more = p.overflowActions
                NotchIconButton(symbol: "ellipsis", label: "More actions") {
                    NotchOverflowMenu.show(more) { perform($0) }
                }
            }
        }
    }

    /// Left of the buttons: counts or a reason in grey, a progress bar, or nothing.
    @ViewBuilder private var leading: some View {
        if let detail = p.detail, detailInFooter(p) {
            Text(detail)
                .font(NotchStyle.Font.meta).foregroundStyle(NotchStyle.metaText)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, 44)
                .layoutPriority(-1)
        } else if p.phase == .running, let value = p.progress {
            HStack(spacing: 8) {
                NotchProgressBar(value: value, tint: NotchStyle.tint(p.phase)).frame(maxWidth: 120)
                Text(NotchStyle.statusText(p)).font(NotchStyle.Font.meta).foregroundStyle(NotchStyle.metaText)
            }
            .padding(.leading, 44)
        }
    }

    private func button(_ item: NotchAlert.Action, fill: Bool = false, row: String? = nil) -> some View {
        Button(item.title) { perform(item.id, row: row) }
            .buttonStyle(NotchButtonStyle(item, fill: fill))
            .accessibilityHint(p.title)
    }

    // MARK: Detail: a running automation's latest activity

    private var runningDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasNotch { band(collapse: true).padding(.bottom, -12) }
            header(p, trailing: Group { if !hasNotch { collapseButton() } })
            Text(p.detail ?? "No activity yet.")
                .font(NotchStyle.Font.message)
                .foregroundStyle(p.detail == nil ? NotchStyle.metaText : Color.white.opacity(0.8))
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .topLeading)
                .padding(.leading, 44)
            footer
        }
        .modifier(IslandPadding(hasNotch: hasNotch))
    }

    // MARK: Detail: a stack as a list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasNotch { band(collapse: true) }
            HStack(spacing: 8) {
                Text(p.title).font(NotchStyle.Font.title).foregroundStyle(.white).lineLimit(1)
                if alert.stackCount > NotchGeometry.maxRows {
                    Text("\(NotchGeometry.maxRows) of \(alert.stackCount)")
                        .font(NotchStyle.Font.meta).foregroundStyle(NotchStyle.metaText)
                }
                Spacer(minLength: 8)
                if let later = p.actions.first(where: { $0.id == "later" }) {
                    Button("All later") { perform(later.id) }
                        .buttonStyle(NotchButtonStyle(primary: false))
                }
                if !hasNotch { collapseButton() }
            }
            .frame(height: 32, alignment: .top)
            ForEach(Array(alert.stack.prefix(NotchGeometry.maxRows).enumerated()), id: \.element.id) { index, member in
                row(member).overlay(alignment: .top) {
                    Rectangle().fill(NotchStyle.hairline).frame(height: 0.5).padding(.leading, 36)
                }
            }
        }
        .modifier(IslandPadding(hasNotch: hasNotch, bottom: NotchGeometry.listBottom))
    }

    private func row(_ member: NotchAlert) -> some View {
        let rp = member.presentation
        return HStack(spacing: 12) {
            NotchIcon(p: rp, diameter: 24, reduceMotion: reduceMotion)
            VStack(alignment: .leading, spacing: 1) {
                Text(rp.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text(rp.phase == .running || rp.phase == .approval ? rp.detail ?? rp.message
                     : rp.detail.map { rp.message + " · " + $0 } ?? rp.message)
                    .font(.system(size: 11)).foregroundStyle(NotchStyle.secondaryText)
            }
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(rp.rowActions) { item in
                    Button(item.title) { perform(item.id, row: member.id) }
                        .buttonStyle(NotchButtonStyle(item))
                        .accessibilityHint(rp.title)
                }
            }
            .fixedSize()
        }
        .frame(height: NotchGeometry.rowHeight)
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
        return VStack(alignment: .leading, spacing: 12) {
            if hasNotch { band(collapse: false).padding(.bottom, -12) }
            header(target, lines: 2).frame(height: 48)
            NotchReplyRow(live: liveField, initial: draft, submit: handlers.submit, cancel: handlers.cancel)
        }
        .modifier(IslandPadding(hasNotch: hasNotch))
    }
}

/// Inside the island: 16 on each side. With a notch the band sits at the top instead of padding.
private struct IslandPadding: ViewModifier {
    let hasNotch: Bool
    var bottom: CGFloat = NotchStyle.padding
    func body(content: Content) -> some View {
        content
            .padding(.top, hasNotch ? 0 : NotchStyle.padding)
            .padding(.horizontal, NotchStyle.padding)
            .padding(.bottom, bottom)
    }
}

/// The answer field with Cancel and Send. Return sends; Escape cancels.
private struct NotchReplyRow: View {
    let live: Bool
    let initial: String
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
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
            .font(NotchStyle.Font.message)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: NotchStyle.buttonHeight)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            Button("Cancel", action: cancel)
                .buttonStyle(NotchButtonStyle(primary: false))
            Button("Send") { submit(text) }
                .buttonStyle(NotchButtonStyle(primary: true))
                .disabled(empty)
        }
        .onAppear {
            text = initial
            if live { DispatchQueue.main.async { focused = true } }
        }
    }
}
