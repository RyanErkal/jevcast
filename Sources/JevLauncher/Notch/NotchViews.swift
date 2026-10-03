import AppKit
import SwiftUI

/// What the island's controls call. On screen these go to `NotchState`; snapshots pass no-ops.
struct NotchHandlers {
    /// An action ID, and the stack row it belongs to (nil for the alert on screen).
    var perform: (String, String?) -> Void
    var submit: (String) -> Void
    var cancel: () -> Void
    /// The reply field's text, as it changes, so an unsent answer can come back with its question.
    var keep: (String) -> Void = { _ in }

    static let none = NotchHandlers(perform: { _, _ in }, submit: { _ in }, cancel: {})
}

/// The panel's root view. The controller sets `state.alert`, `state.mode`, `state.expanded`, and `state.closing`;
/// this view draws them. The panel is already at its largest size, so only the shape moves.
struct NotchAlertView: View {
    @ObservedObject var state: NotchState
    let action: (String) -> Void
    let hover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let alert = state.alert {
                NotchIsland(alert: alert, geometry: state.geometry, mode: mode, replyTarget: state.replyTarget,
                            handlers: handlers, draft: state.replyDraft, canvas: state.geometry.maxShapeSize,
                            contentHidden: state.closing, retracting: !state.expanded)
                    // Reduce Motion: no growth out of the notch, only a cross-fade.
                    .opacity(reduceMotion && !state.expanded ? 0 : 1)
                    .onHover(perform: hover)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var mode: NotchMode {
        guard state.expanded || reduceMotion else { return .collapsed }
        return NotchMode(state.mode)
    }

    private var handlers: NotchHandlers {
        let state = self.state
        let action = self.action
        return NotchHandlers(perform: { id, row in row == nil ? action(id) : state.perform(id, on: row) },
                             submit: { state.submitReply($0) },
                             cancel: { state.cancelReply() },
                             keep: { state.keepDraft($0) })
    }
}

/// The black island in one mode. It draws only from its inputs, so snapshots can render any state.
/// Width and height follow separate springs, so the shape widens slightly ahead of growing down.
/// Content is laid out at its final size and clipped to the moving outline; only the path, opacity, and offset animate.
struct NotchIsland: View {
    let alert: NotchAlert
    let geometry: NotchGeometry
    let mode: NotchMode
    var replyTarget: String?
    var handlers: NotchHandlers = .none
    /// False in snapshots: the reply field draws as text, since offscreen rendering cannot draw a live field.
    var liveField = true
    /// Text shown in the reply field when it opens: the unsent draft for this question on screen, or a snapshot's text.
    var draft = ""
    /// A fixed area to lay out in, larger than any mode. Nil sizes the view to the shape, for snapshots.
    var canvas: CGSize?
    /// True while the island closes: content fades out before the shape retracts.
    var contentHidden = false
    /// Picks the faster retract springs.
    var retracting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var parts

    private var p: NotchPresentation { alert.presentation }
    private var hasNotch: Bool { geometry.hasNotch }

    /// Content identity: a new alert or mode cross-fades. A reply is keyed by the question it answers, so its field,
    /// draft, and focus stay when that question joins or leaves a stack.
    struct ContentKey: Hashable {
        let id: String
        let mode: NotchMode
    }

    static func contentKey(alert: NotchAlert, mode: NotchMode, replyTarget: String?) -> ContentKey {
        ContentKey(id: mode == .reply ? (replyTarget ?? alert.id) : alert.id, mode: mode)
    }

    var body: some View {
        let size = NotchStyle.size(mode, alert, geometry)
        let area = canvas ?? size
        let outline = NotchStyle.outline(mode, hasNotch: hasNotch)
        ZStack(alignment: .top) {
            // One keyed child: a new alert or mode cross-fades instead of changing in place.
            ForEach([Self.contentKey(alert: alert, mode: mode, replyTarget: replyTarget)], id: \.self) { key in
                let own = NotchStyle.size(key.mode, alert, geometry)
                content(key.mode)
                    .frame(width: own.width, height: own.height, alignment: .top)
                    .frame(width: area.width, height: area.height, alignment: .top)
                    .transition(NotchMotion.contentTransition(reduceMotion: reduceMotion))
            }
        }
        .opacity(contentHidden ? 0 : 1)
        .frame(width: area.width, height: area.height, alignment: .top)
        .animation(NotchMotion.height(closing: retracting, reduceMotion: reduceMotion)) {
            $0.modifier(IslandOutline(height: size.height, outline: outline, openness: mode.isOpen ? 1 : 0,
                                      band: hasNotch ? geometry.notchHeight : 0))
        }
        .animation(NotchMotion.width(closing: retracting, reduceMotion: reduceMotion)) {
            $0.modifier(IslandWidth(width: size.width))
        }
        .contentShape(NotchIslandShape(width: size.width, height: size.height, outline: outline))
        .scaleEffect(x: 1, y: !hasNotch && mode == .collapsed ? 0.6 : 1, anchor: .top)
        .opacity(!hasNotch && mode == .collapsed ? 0 : 1)
        .offset(y: hasNotch ? 0 : (mode == .collapsed ? -NotchGeometry.pillBody : NotchGeometry.topGap))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(p.title). \(p.message)\(p.detail.map { ". " + $0 } ?? "")")
    }

    @ViewBuilder private func content(_ mode: NotchMode) -> some View {
        switch mode {
        case .collapsed: Color.clear
        case .compact: compact
        case .card: card
        case .detail: if alert.isStack { list } else { runningDetail }
        case .reply: reply
        }
    }

    /// Every action names the alert it was drawn for, also from a menu that returns later, so the controller can
    /// refuse it once that alert has changed or gone.
    private func perform(_ id: String, row: String? = nil) { handlers.perform(id, row ?? alert.id) }

    // MARK: Compact: the automation's icon (or a few, when several run) left of the notch, one status mark right of it.
    // A click opens the detail.

    private var compact: some View {
        HStack(spacing: 8) {
            Group {
                if p.isRunningStack {
                    NotchIconStack(identities: p.identities, diameter: 20)
                } else {
                    NotchIcon(p: p, diameter: 20, reduceMotion: reduceMotion, showsBadge: false)
                }
            }
            .matchedGeometryEffect(id: "icon", in: parts)
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
                .matchedGeometryEffect(id: "icon", in: parts)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title)
                    .font(NotchStyle.Font.title).foregroundStyle(.white)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "title", in: parts, properties: .position)
                subtitleText(p)
                    .font(NotchStyle.Font.message).foregroundStyle(NotchStyle.secondaryText)
                    .lineLimit(lines)
            }
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(minHeight: 32)
    }

    /// A running alert's line is its last finished stage or retry, ticking only while a known retry time counts down.
    @ViewBuilder private func subtitleText(_ p: NotchPresentation) -> some View {
        if p.phase == .running, p.retry?.at != nil {
            TimelineView(.periodic(from: Date(), by: 1)) { context in Text(p.runningLine(now: context.date)) }
        } else {
            Text(p.phase == .running ? p.runningLine(now: Date()) : subtitle(p))
        }
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
            overflow(p.overflowActions)
        }
    }

    @ViewBuilder private func overflow(_ more: [NotchAlert.Action], row: String? = nil, title: String? = nil) -> some View {
        if !more.isEmpty {
            NotchIconButton(symbol: "ellipsis", label: title.map { "More actions for \($0)" } ?? "More actions") {
                NotchOverflowMenu.show(more) { perform($0, row: row) }
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

    // MARK: Detail: one running automation, compact. A click on it or Details opens the run; Cancel is in the menu.

    private var runningDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasNotch { band(collapse: true) }
            header(p, trailing: Group {
                if !hasNotch { HStack(spacing: 8) { NotchStatus(p: p, reduceMotion: reduceMotion); collapseButton() } }
            })
            .contentShape(Rectangle())
            .onTapGesture { perform(NotchAlert.detailsAction) }
            .accessibilityAction(named: "Open details") { perform(NotchAlert.detailsAction) }
            HStack(spacing: 8) {
                NotchRunningMeta(p: p)
                    .padding(.leading, 44)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                ForEach(p.visibleActions) { button($0) }
                overflow(p.overflowActions)
            }
            .padding(.top, 12)
        }
        .modifier(IslandPadding(hasNotch: hasNotch))
    }

    // MARK: Detail: a stack as a list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasNotch { band(collapse: true) }
            HStack(spacing: 8) {
                Text(p.title).font(NotchStyle.Font.title).foregroundStyle(.white).lineLimit(1)
                    .matchedGeometryEffect(id: "title", in: parts, properties: .position)
                if alert.stackCount > NotchGeometry.maxRows {
                    Text("\(NotchGeometry.maxRows) of \(alert.stackCount)")
                        .font(NotchStyle.Font.meta).foregroundStyle(NotchStyle.metaText)
                }
                Spacer(minLength: 8)
                if !p.isRunningStack, let later = p.actions.first(where: { $0.id == "later" }) {
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
                Text(rowLine(rp))
                    .font(.system(size: 11)).foregroundStyle(NotchStyle.secondaryText)
            }
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            if rp.phase == .running { NotchStatus(p: rp, reduceMotion: reduceMotion, ringSize: 12) }
            HStack(spacing: 8) {
                ForEach(rp.rowActions) { item in
                    Button(item.title) { perform(item.id, row: member.id) }
                        .buttonStyle(NotchButtonStyle(item))
                        .accessibilityHint(rp.title)
                }
                overflow(rp.rowMenu, row: member.id, title: rp.title)
            }
            .fixedSize()
        }
        .frame(height: NotchGeometry.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rp.title). \(rowLine(rp))")
    }

    private func rowLine(_ rp: NotchPresentation) -> String {
        switch rp.phase {
        case .running: return rp.runningLine(now: Date())
        case .approval: return rp.detail ?? rp.message
        default: return rp.detail.map { rp.message + " · " + $0 } ?? rp.message
        }
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
            NotchReplyRow(live: liveField, initial: draft, submit: handlers.submit, cancel: handlers.cancel, keep: handlers.keep)
        }
        .modifier(IslandPadding(hasNotch: hasNotch))
    }
}

/// Passes the animated width down to `IslandOutline`, which follows its own spring.
private struct IslandWidth: ViewModifier, Animatable {
    var width: CGFloat
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }
    func body(content: Content) -> some View { content.environment(\.notchIslandWidth, width) }
}

private struct IslandWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

private extension EnvironmentValues {
    var notchIslandWidth: CGFloat {
        get { self[IslandWidthKey.self] }
        set { self[IslandWidthKey.self] = newValue }
    }
}

/// Draws the surface behind the content and clips the content to it, at the animated size and radii.
/// `openness` rides the height spring, so the rim fades in as the shape grows out of the black notch.
private struct IslandOutline: ViewModifier, Animatable {
    var height: CGFloat
    var outline: NotchShape
    /// 0 closed or compact (opaque black), 1 open.
    var openness: CGFloat
    /// The notch's height, or 0 without one.
    let band: CGFloat
    @Environment(\.notchIslandWidth) private var width

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, NotchShape.AnimatableData>> {
        get { AnimatablePair(height, AnimatablePair(openness, outline.animatableData)) }
        set { height = newValue.first; openness = newValue.second.first; outline.animatableData = newValue.second.second }
    }

    func body(content: Content) -> some View {
        let shape = NotchIslandShape(width: width, height: height, outline: outline)
        content
            .clipShape(shape)
            .background(alignment: .top) { NotchSurface(shape: shape, height: height, band: band, openness: openness) }
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
    let keep: (String) -> Void
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
        .onChange(of: text) { _, new in keep(new) }
    }
}
