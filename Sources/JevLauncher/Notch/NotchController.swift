import AppKit
import SwiftUI

/// Shows notch alerts: one alert, a stack, or a pill, out of the MacBook notch. Automation alerts never open by
/// themselves. A run shows in the pill while it works; then the pill's ring turns into a mark. A finished run's outcome
/// leaves after a few seconds; a question or an approval stays until clicked. A click opens the card.
/// On a screen without a notch the shape drops from the top centre.
/// The panel takes keyboard focus only after the user clicks Reply. It plays no sound.
/// A press outside an open card, list, or reply closes it (`outsideClick`): anything that rests in the pill returns to
/// it, alerts that offer Later go as Later does, and alerts without Later stay.
/// It hides, without losing anything, while the session is locked or a menu is open under it.
@MainActor
final class NotchAlertController {
    static let shared = NotchAlertController()

    /// Called with the displayed alert and the action ID. "dismiss" is sent when an alert closes on its own.
    /// Stack buttons arrive with `NotchQueue.stackID`.
    var onAction: ((NotchAlert, String) -> Void)?
    /// Whether a remembered alert still applies, for "Show notifications". Nil keeps every one.
    var stillApplies: ((NotchAlert) -> Bool)?
    /// Called once per alert and content after it was actually drawn on screen: the panel is visible, the session is
    /// unlocked, and the expanded shape has finished growing. A queued or hidden alert is never reported. A later state
    /// of the same run (a new question, a success after an approval) is reported again (`NotchPresentedLog`).
    /// A stack reports its members only when its list is open, because a collapsed stack shows titles only.
    var onPresented: ((NotchAlert) -> Void)?
    /// Seconds a failure stays up when the pointer is not over it.
    var failureSeconds: TimeInterval {
        get { queue.failureSeconds }
        set { queue.failureSeconds = min(max(newValue, 3), 60) }
    }
    /// The old name for `failureSeconds`.
    var visibleSeconds: TimeInterval {
        get { failureSeconds }
        set { failureSeconds = newValue }
    }

    let state = NotchState()
    private(set) var queue = NotchQueue()
    /// Alerts that closed recently, newest batch last, for "Show notifications". A stack closes as one batch.
    private(set) var recent: [[NotchAlert]] = []
    private var panel: NotchPanel?
    private var session: NotchSession?
    private var sessionAvailable = NotchSession.isAvailable
    private var menus = NotchMenuObservation()
    private var hovering = false
    private var timerTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var closing = NotchCloseSequence()
    /// The presentation an animation completion belongs to. Only the current one may record an alert as shown.
    private var tickets = NotchPresentationTickets()
    private var pointerTimer: Timer?
    private var inputReadyAt = Date.distantFuture
    private var announced: Set<String> = []
    /// Alerts already reported through `onPresented`, by ID and what they showed.
    private var presented = NotchPresentedLog()
    /// Watches for a press outside the island only while an open card, list, or reply is on screen.
    private lazy var outside = NotchOutsideClick { [weak self] point in self?.pressed(at: point) }

    deinit { pointerTimer?.invalidate() }

    init() {
        session = NotchSession { [weak self] available in
            guard let self else { return }
            self.sessionAvailable = available
            self.refresh()
        }
        state.performHandler = { [weak self] id, action in self?.perform(action, on: id) }
        state.hoverHandler = { [weak self] inside in self?.hover(inside) }
    }

    // MARK: Public

    /// Adds an alert, or replaces the one with the same ID or run.
    func show(_ alert: NotchAlert) {
        guard queue.add(alert) else { return }
        refresh()
    }

    /// Replaces an alert only when it is still waiting or on screen.
    func update(_ alert: NotchAlert) {
        guard queue.contains(alert.id) else { return }
        show(alert)
    }

    /// Removes an alert that no longer applies, for example after the user approved in another window.
    func withdraw(id: String) {
        guard queue.remove(id) != nil else { return }
        refresh()
    }

    /// Removes every alert for a run, such as its running indicator when it finishes.
    func withdraw(runID: String, kinds: Set<NotchAlert.Kind>? = nil) {
        let gone = queue.removeAll { $0.runID == runID && (kinds?.contains($0.kind) ?? true) }
        if !gone.isEmpty { refresh() }
    }

    func alert(_ id: String) -> NotchAlert? { queue.alert(id) }
    var current: NotchAlert? { state.alert }

    /// Shows the most recent alerts again that still apply. Returns false when there is none. Asked for, they come back
    /// as cards, also a finished run's outcome that first showed only in the pill.
    @discardableResult func showLast() -> Bool {
        recent = recent.map { $0.filter { stillApplies?($0) ?? true } }.filter { !$0.isEmpty }
        guard let batch = recent.popLast() else { return false }
        for var alert in batch where !queue.containsRunOrID(alert) {
            alert.minimized = false
            queue.add(alert)
        }
        refresh()
        return true
    }

    // MARK: Actions

    /// Runs an action for the alert it was drawn for (`alertID`; nil means the one on screen). Buttons and menus can
    /// fire after that alert changed or left, for example a Cancel Run menu left open while the run finished; such an
    /// action does nothing rather than reach whatever shows now.
    private func perform(_ action: String, on alertID: String?) {
        guard let shown = state.alert else { return }
        let target = alertID ?? shown.id
        switch action {
        case NotchAlert.expandAction:
            endReply()
            let resting = Self.restingMode(for: shown)
            setMode(state.mode == resting ? Self.openMode(for: shown) : resting)
            return
        case NotchAlert.collapseAction:
            // Cancel or Escape in a reply discards what was typed.
            if state.mode == .reply, let target = state.replyTarget { state.forgetDraft(target) }
            endReply()
            setMode(Self.restingMode(for: shown))
            return
        case NotchAlert.replyAction:
            beginReply(target)
            return
        case NotchAlert.detailsAction:
            // Opening a running automation's run does not end it: its live indicator stays and rests again.
            guard let running = queue.alert(target), running.kind == .running else { break }
            endReply()
            setMode(Self.restingMode(for: shown))
            onAction?(running, action)
            return
        default: break
        }
        switch Self.actionTarget(action, origin: target, shown: shown, queue: queue) {
        case nil:
            return
        case .stack(let members)?:
            _ = queue.removeAll { alert in members.contains { $0.id == alert.id } }
            remember(members)
            if action == "later" || action == NotchAlert.dismissAction {
                for member in members { onAction?(member, action) }
            } else {
                onAction?(shown, action)
            }
        case .alert(let alert)?:
            if action.hasPrefix("reply:") { endReply() }
            if action.hasPrefix("reply:") || action.hasPrefix("choice:") { state.forgetDraft(alert.id) }
            queue.remove(alert.id)
            remember([alert])
            onAction?(alert, action)
        }
        refresh()
    }

    enum ActionTarget: Equatable {
        case stack([NotchAlert])
        case alert(NotchAlert)
    }

    /// What an action drawn for `origin` may act on now: that alert while it still waits and still offers the action,
    /// or the stack while the stack shows. Nil when the origin has gone or changed, so a late press does nothing.
    static func actionTarget(_ action: String, origin: String, shown: NotchAlert, queue: NotchQueue) -> ActionTarget? {
        if origin == NotchQueue.stackID {
            guard shown.id == NotchQueue.stackID, shown.isStack, shown.offers(action) else { return nil }
            return .stack(shown.stack)
        }
        guard let alert = queue.alert(origin), alert.offers(action) else { return nil }
        return .alert(alert)
    }

    // MARK: A press outside

    /// What a press outside the open island does.
    enum OutsideClick: Equatable {
        /// The open card, list, or reply returns to how it rests: running work to its pill, other alerts to their card.
        /// Nothing leaves the screen and the runs go on.
        case rest
        /// These alerts offer Later and close as Later does: they leave the screen and wait in Show notifications.
        /// Nothing is answered, approved, retried, or cancelled, so a question or approval stays unfinished. Alerts
        /// shown with them that do not offer Later stay, and what stays rests.
        case later([NotchAlert])
    }

    /// Nil leaves the island as it is: a pill is already minimized, and a card that does not offer Later (a failure, or
    /// the result of Approve all with its Undo) is never removed by a press elsewhere. An open reply closes as Later with
    /// its question, and its unsent text comes back when that exact question opens again. `later` names the alerts as
    /// the queue holds them.
    static func outsideClick(shown: NotchAlert, mode: NotchState.Mode, queue: NotchQueue) -> OutsideClick? {
        guard mode != .pill else { return nil }
        let resting = restingMode(for: shown)
        if resting == .pill { return .rest }
        let members = (shown.isStack ? shown.stack : [shown]).compactMap { queue.alert($0.id) }
        let later = members.filter { $0.offers("later") }
        if !later.isEmpty { return .later(later) }
        return members.isEmpty || mode == resting ? nil : .rest
    }

    /// Whether a press outside may act now: once the shape has settled (the same wait as pointer input, so a press made
    /// as an alert appears does nothing), never while the island's own menu is open or has just closed, and never for a
    /// press on the island itself.
    static func acceptsOutsidePress(visible: Bool, available: Bool, expanded: Bool, closing: Bool, ready: Bool,
                                    ownMenu: Bool, inside: Bool) -> Bool {
        visible && available && expanded && !closing && ready && !ownMenu && !inside
    }

    /// Whether to watch for presses outside: only while an open card, list, or reply is on screen.
    static func watchesOutside(visible: Bool, showing: Bool, closing: Bool, available: Bool, mode: NotchState.Mode) -> Bool {
        visible && showing && !closing && available && mode != .pill
    }

    /// A press anywhere while an open card, list, or reply shows (`acceptsOutsidePress`).
    private func pressed(at point: CGPoint) {
        guard let panel, let shown = state.alert,
              Self.acceptsOutsidePress(visible: panel.isVisible, available: available, expanded: state.expanded,
                                       closing: state.closing, ready: Date() >= inputReadyAt,
                                       ownMenu: NotchMenuGuard.ownMenuActive(now: Date()),
                                       inside: state.geometry.contains(point, mode: state.mode, alert: shown)) else { return }
        switch Self.outsideClick(shown: shown, mode: state.mode, queue: queue) {
        case nil:
            return
        case .rest?:
            // The draft is already kept; ending the reply gives keyboard focus back.
            endReply()
            setMode(Self.restingMode(for: shown))
        case .later(let members)?:
            endReply()
            _ = queue.removeAll { alert in members.contains { $0.id == alert.id } }
            remember(members)
            for member in members { onAction?(member, "later") }
            refresh()
            // What stays, such as a result with Undo that was in the list, rests instead of staying open.
            if queue.presentation != nil, let now = state.alert { setMode(Self.restingMode(for: now)) }
        }
    }

    /// Starts or stops the outside watch (`watchesOutside`).
    private func updateOutsideWatch() {
        let watch = Self.watchesOutside(visible: panel?.isVisible == true, showing: state.alert != nil, closing: state.closing,
                                        available: available, mode: state.mode)
        if watch { outside.start() } else { outside.stop() }
    }

    /// A draft stays while its exact question can still come back: in the queue, or closed into Show notifications.
    static func draftStillWaits(_ draft: NotchState.Draft, queue: NotchQueue, recent: [[NotchAlert]]) -> Bool {
        queue.alert(draft.question.id) == draft.question || recent.contains { $0.contains(draft.question) }
    }

    private func beginReply(_ target: String) {
        guard let panel, Self.replyAlert(in: state.alert, target: target) != nil else { return }
        state.replyTarget = target
        setMode(.reply)
        panel.allowsKey = true
        panel.makeKey()
    }

    private func endReply() {
        let wasReply = state.mode == .reply
        state.endReply()
        if wasReply { deferPointerInput() }
        updateOutsideWatch()
        guard let panel else { return }
        panel.allowsKey = false
        if panel.isKeyWindow { panel.resignKey() }
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside { queue.pauseTimers(); timerTask?.cancel() } else { scheduleTimers() }
    }

    private func remember(_ alerts: [NotchAlert]) {
        let keep = alerts.filter { $0.kind != .running && !$0.id.hasPrefix("test-") }
        guard !keep.isEmpty else { return }
        let ids = Set(keep.map(\.id))
        recent = recent.map { $0.filter { !ids.contains($0.id) } }.filter { !$0.isEmpty }
        recent.append(keep)
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
    }

    // MARK: Presentation

    /// The mode an alert rests in: a pill for running indicators and finished runs' outcomes, otherwise the card.
    static func restingMode(for alert: NotchAlert) -> NotchState.Mode {
        let members = alert.isStack ? alert.stack : [alert]
        return members.allSatisfy { $0.kind == .running } || members.allSatisfy(\.minimized) ? .pill : .card
    }

    /// The mode a click on a resting alert opens: a stack's list or a running card, otherwise the alert's card.
    static func openMode(for alert: NotchAlert) -> NotchState.Mode {
        alert.isStack || alert.kind == .running ? .detail : .card
    }

    /// The mode after the alert on screen changes. Detail and reply stay while the same alert or stack stays.
    static func nextMode(previous: NotchAlert?, previousMode: NotchState.Mode, next: NotchAlert, replyTarget: String?) -> NotchState.Mode {
        let resting = restingMode(for: next)
        // A reply stays open while its exact question stays, also when the question joins or leaves a stack.
        if previousMode == .reply, let replyTarget, let old = replyAlert(in: previous, target: replyTarget) {
            return old == replyAlert(in: next, target: replyTarget) ? .reply : resting
        }
        // An open list of running automations that drops to one keeps that one open, instead of snapping shut.
        if let previous, previous.isStack, previousMode == .detail, next.kind == .running, !next.isStack,
           previous.stack.contains(where: { $0.id == next.id }) { return .detail }
        // And an open running card that more automations join opens as their list, instead of snapping to the pill.
        if let previous, !previous.isStack, previous.kind == .running, previousMode == .detail, next.isStack, resting == .pill,
           next.stack.contains(where: { $0.id == previous.id }) { return .detail }
        // A running card the user opened shows its run's outcome as a card; a closed one only changes its mark.
        if let previous, !previous.isStack, previous.kind == .running, previousMode == .detail, !next.isStack, next.minimized,
           next.runID != nil, next.runID == previous.runID, next.automationID == previous.automationID { return .card }
        guard let previous, previous.id == next.id else { return resting }
        switch previousMode {
        case .reply:
            guard let replyTarget else { return resting }
            let old = replyAlert(in: previous, target: replyTarget)
            let new = replyAlert(in: next, target: replyTarget)
            return old != nil && old == new ? .reply : resting
        case .detail: return resting == .pill && next.kind != .running && !next.minimized ? .card : .detail
        case .pill, .card: return resting
        }
    }

    static func replyAlert(in alert: NotchAlert?, target: String) -> NotchAlert? {
        guard let alert else { return nil }
        let targetAlert = alert.id == target ? alert : alert.stack.first { $0.id == target }
        guard let targetAlert, targetAlert.kind == .question, targetAlert.allowsReply else { return nil }
        return targetAlert
    }

    private var available: Bool { sessionAvailable && !menus.isOpen }

    /// Brings the screen in line with the queue.
    private func refresh() {
        state.keepDrafts { [queue, recent] in Self.draftStillWaits($0, queue: queue, recent: recent) }
        // An alert that left or changed is reported again when it is next drawn.
        presented.keep(queue.entries.map(\.alert))
        guard let next = queue.presentation else { close(); return }
        guard available else {
            queue.pauseTimers()
            timerTask?.cancel()
            hidePanel()
            watchMenus()
            return
        }
        present(next)
        scheduleTimers()
        watchMenus()
    }

    private func present(_ alert: NotchAlert) {
        closing.cancel()
        guard let screen = NSScreen.screens.first else { return }
        let geometry = NotchGeometry(screen: screen)
        let previous = state.alert
        let wasExpanded = state.expanded
        let previousMode = state.mode
        let mode = Self.nextMode(previous: previous, previousMode: state.mode, next: alert, replyTarget: state.replyTarget)
        if mode != .reply { endReply() }
        let ticket = tickets.issue(alertID: alert.id, mode: mode)
        let panel = self.panel ?? makePanel()
        let opening = previous == nil || !panel.isVisible
        state.geometry = geometry
        // The panel stays at its largest size, so the SwiftUI shape does all the visible motion.
        if panel.frame != geometry.maxPanelFrame { panel.setFrame(geometry.maxPanelFrame, display: false) }
        if opening {
            state.alert = alert
            state.mode = mode
            state.expanded = false
            state.closing = false
            // Lay out and draw the collapsed shape at notch size before the panel is on screen.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            panel.orderFrontRegardless()
            panel.ignoresMouseEvents = true
            // Grow on the next pass, after the notch-size frame is on screen.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tickets.isCurrent(ticket), self.queue.presentation != nil, self.available,
                      self.panel?.isVisible == true else { return }
                self.withMotion({ self.state.expanded = true }, completion: { [weak self] in self?.reportPresented(ticket) })
            }
        } else {
            // A new alert or mode morphs from wherever the shape is now, also halfway through a close.
            withMotion({ state.present(alert, mode: mode) }, completion: { [weak self] in self?.reportPresented(ticket) })
        }
        if opening || !wasExpanded || previous != alert || previousMode != mode { deferPointerInput() }
        watchPointer()
        updatePointerInput()
        updateOutsideWatch()
        announce(alert)
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel()
        panel.contentView = NSHostingView(rootView: NotchAlertView(state: state) { [weak self] action in
            self?.state.perform(action)
        } hover: { [weak self] inside in
            self?.state.hover(inside)
        })
        self.panel = panel
        return panel
    }

    private func watchPointer() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerInput() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func setMode(_ mode: NotchState.Mode) {
        guard panel != nil, state.mode != mode, let shown = state.alert else { return }
        deferPointerInput()
        let ticket = tickets.issue(alertID: shown.id, mode: mode)
        withMotion({ state.mode = mode }, completion: { [weak self] in self?.reportPresented(ticket) })
        // Rows a list now draws start their time; rows it no longer draws wait again.
        scheduleTimers()
        updateOutsideWatch()
    }

    /// Reports what is on screen now, once per alert, when it is really there: only for the presentation still
    /// current when its animation settles. A superseded animation, a hide, or a close records nothing.
    private func reportPresented(_ ticket: NotchPresentationTickets.Ticket) {
        guard tickets.isCurrent(ticket), let onPresented, let panel, panel.isVisible, available, state.expanded, !state.closing,
              let shown = state.alert, shown.id == ticket.alertID, state.mode == ticket.mode,
              panel.occlusionState.contains(.visible) else { return }
        let alerts = Self.presentedAlerts(shown, mode: state.mode)
        presented.keep(queue.entries.map(\.alert) + alerts)
        for alert in presented.record(alerts) { onPresented(alert) }
    }

    /// The alerts `mode` draws: a single alert, the rows a stack's open list draws (the first `NotchGeometry.maxRows`;
    /// the rest are only counted, so they are not presented), or finished runs whose outcome mark the pill draws.
    static func presentedAlerts(_ shown: NotchAlert, mode: NotchState.Mode) -> [NotchAlert] {
        guard shown.kind != .running else { return [] }
        if shown.isStack {
            switch mode {
            case .detail: return shown.stack.prefix(NotchGeometry.maxRows).filter { $0.kind != .running }
            case .pill: return shown.stack.filter(\.minimized)
            case .card, .reply: return []
            }
        }
        return mode == .pill && !shown.minimized ? [] : [shown]
    }

    // Ignore input while the shape morphs. Its final outline is not its visible outline yet.
    private func deferPointerInput() {
        inputReadyAt = Date().addingTimeInterval(0.8)
        panel?.ignoresMouseEvents = true
    }

    static func acceptsPointer(expanded: Bool, visible: Bool, ready: Bool, inside: Bool) -> Bool {
        expanded && visible && ready && inside
    }

    private func updatePointerInput() {
        guard let panel else { return }
        let inside = state.alert.map { state.geometry.contains(NSEvent.mouseLocation, mode: state.mode, alert: $0) } ?? false
        panel.ignoresMouseEvents = !Self.acceptsPointer(expanded: state.expanded, visible: panel.isVisible,
                                                       ready: Date() >= inputReadyAt, inside: inside)
        if hovering != inside && state.expanded && panel.isVisible { hover(inside) }
    }

    /// VoiceOver hears a new alert once. Running indicators are not announced.
    private func announce(_ alert: NotchAlert) {
        let ids = alert.isStack ? alert.stack.map(\.id) : [alert.id]
        let fresh = ids.filter { !announced.contains($0) }
        announced.formIntersection(Set(queue.entries.map(\.alert.id)))
        guard !fresh.isEmpty, alert.kind != .running, let panel else { return }
        announced.formUnion(fresh)
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "\(alert.title). \(alert.message)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func hidePanel() {
        pointerTimer?.invalidate(); pointerTimer = nil
        tickets.invalidate()
        closing.cancel()
        endReply()
        outside.stop()
        // A hidden panel never sends the pointer's exit.
        hovering = false
        panel?.orderOut(nil)
        state.alert = nil
        state.expanded = false
        state.closing = false
        state.mode = .card
    }

    private func close() {
        pointerTimer?.invalidate(); pointerTimer = nil
        timerTask?.cancel()
        menuTask?.cancel()
        endReply()
        outside.stop()
        hovering = false
        tickets.invalidate()
        guard state.alert != nil, let panel, panel.isVisible else { finishClose(); return }
        panel.ignoresMouseEvents = true
        let token = closing.begin()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Content fades first; then the shape retracts into the notch; the panel leaves only once the shape has settled.
        withAnimation(NotchMotion.contentHide(reduceMotion: reduceMotion)) {
            state.closing = true
        } completion: { [weak self] in
            MainActor.assumeIsolated { self?.retract(token, reduceMotion: reduceMotion) }
        }
    }

    private func retract(_ token: Int, reduceMotion: Bool) {
        guard closing.isCurrent(token), queue.presentation == nil else { return }
        withAnimation(NotchMotion.settle(closing: true, reduceMotion: reduceMotion), completionCriteria: .removed) {
            state.expanded = false
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing.finish(token), self.queue.presentation == nil else { return }
                self.finishClose()
            }
        }
    }

    private func finishClose() {
        tickets.invalidate()
        closing.cancel()
        outside.stop()
        panel?.orderOut(nil)
        state.alert = nil
        state.expanded = false
        state.closing = false
        state.mode = .card
    }

    // MARK: Timers

    private func scheduleTimers() {
        timerTask?.cancel()
        guard !hovering, available else { return }
        queue.startTimers(now: Date(), drawn: Set(state.alert.map { Self.presentedAlerts($0, mode: state.mode).map(\.id) } ?? []))
        guard let deadline = queue.nextDeadline else { return }
        timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, deadline.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let gone = self.queue.expire(now: Date())
            self.remember(gone)
            for alert in gone { self.onAction?(alert, NotchAlert.dismissAction) }
            self.refresh()
        }
    }

    /// While anything waits, checks once a second for a menu under the notch. Stops when the queue is empty.
    private func watchMenus() {
        guard menuTask == nil || menuTask?.isCancelled == true else { return }
        let owner = menus.begin()
        menuTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.checkMenus(owner: owner) == true else { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard self?.menus.finish(owner) == true else { return }
            self?.menuTask = nil
        }
    }

    private func checkMenus(owner: UUID) -> Bool {
        guard !queue.isEmpty, let screen = NSScreen.screens.first else { return false }
        let area = NotchGeometry(screen: screen).panelFrame(.detail, alert: queue.presentation)
        let open = NotchMenuGuard.menuOpen(over: area, screen: screen.frame)
        if menus.update(open, owner: owner) { refresh() }
        return true
    }

    private func withMotion(_ change: () -> Void) {
        withAnimation(NotchStyle.morph(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), change)
    }

    private func withMotion(_ change: () -> Void, completion: @escaping @MainActor () -> Void) {
        withAnimation(NotchStyle.morph(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), change) {
            MainActor.assumeIsolated { completion() }
        }
    }
}

/// Generations of what the notch presents. Each presentation or mode change issues a ticket; a hide or close voids the
/// current one. An animation completion records an alert as shown only with the ticket that is still current.
struct NotchPresentationTickets {
    struct Ticket: Equatable {
        let generation: Int
        let alertID: String
        let mode: NotchState.Mode
    }

    private(set) var current: Ticket?
    private var generation = 0

    mutating func issue(alertID: String, mode: NotchState.Mode) -> Ticket {
        generation += 1
        let ticket = Ticket(generation: generation, alertID: alertID, mode: mode)
        current = ticket
        return ticket
    }

    mutating func invalidate() {
        generation += 1
        current = nil
    }

    func isCurrent(_ ticket: Ticket) -> Bool { ticket == current }
}
