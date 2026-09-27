import AppKit
import SwiftUI

/// Shows notch alerts: one alert, a stack, or a running pill, out of the MacBook notch.
/// On a screen without a notch the shape drops from the top centre.
/// The panel takes keyboard focus only after the user clicks Reply. It plays no sound.
/// It hides, without losing anything, while the session is locked or a menu is open under it.
@MainActor
final class NotchAlertController {
    static let shared = NotchAlertController()

    /// Called with the alert ID and the action ID. "dismiss" is sent when an alert closes on its own.
    /// Stack buttons arrive with `NotchQueue.stackID`.
    var onAction: ((String, String) -> Void)?
    /// Whether a remembered alert still applies, for "Show notifications". Nil keeps every one.
    var stillApplies: ((NotchAlert) -> Bool)?
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
    private var menuOpen = false
    private var hovering = false
    private var timerTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var announced: Set<String> = []

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

    /// Shows the most recent alerts again that still apply. Returns false when there is none.
    @discardableResult func showLast() -> Bool {
        recent = recent.map { $0.filter { stillApplies?($0) ?? true } }.filter { !$0.isEmpty }
        guard let batch = recent.popLast() else { return false }
        for alert in batch { queue.add(alert) }
        refresh()
        return true
    }

    // MARK: Actions

    private func perform(_ action: String, on alertID: String?) {
        guard let shown = state.alert else { return }
        let target = alertID ?? shown.id
        switch action {
        case NotchAlert.expandAction:
            setMode(state.mode == .detail ? Self.restingMode(for: shown) : .detail)
            return
        case NotchAlert.collapseAction:
            endReply()
            setMode(Self.restingMode(for: shown))
            return
        case NotchAlert.replyAction:
            beginReply(target)
            return
        default: break
        }
        if target == NotchQueue.stackID {
            let members = shown.stack
            _ = queue.removeAll { alert in members.contains { $0.id == alert.id } }
            remember(members)
            if action == "later" || action == NotchAlert.dismissAction {
                for member in members { onAction?(member.id, action) }
            } else {
                onAction?(NotchQueue.stackID, action)
            }
        } else {
            if action.hasPrefix("reply:") { endReply() }
            if let alert = queue.remove(target) { remember([alert]) }
            onAction?(target, action)
        }
        refresh()
    }

    private func beginReply(_ target: String) {
        guard let panel else { return }
        state.replyTarget = target
        setMode(.reply)
        panel.allowsKey = true
        panel.makeKey()
    }

    private func endReply() {
        state.replyTarget = nil
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

    /// The mode an alert rests in: a pill for running indicators, otherwise the card.
    static func restingMode(for alert: NotchAlert) -> NotchState.Mode {
        alert.kind == .running && (alert.stack.isEmpty || alert.stack.allSatisfy { $0.kind == .running }) ? .pill : .card
    }

    /// The mode after the alert on screen changes. Detail and reply stay while the same alert or stack stays.
    static func nextMode(previous: NotchAlert?, previousMode: NotchState.Mode, next: NotchAlert, replyTarget: String?) -> NotchState.Mode {
        let resting = restingMode(for: next)
        guard let previous, previous.id == next.id else { return resting }
        switch previousMode {
        case .reply:
            guard let replyTarget else { return resting }
            let stillThere = next.id == replyTarget || next.stack.contains { $0.id == replyTarget }
            return stillThere ? .reply : resting
        case .detail: return resting == .pill && next.kind != .running ? .card : .detail
        case .pill, .card: return resting
        }
    }

    private var available: Bool { sessionAvailable && !menuOpen }

    /// Brings the screen in line with the queue.
    private func refresh() {
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
        closeTask?.cancel()
        guard let screen = NSScreen.screens.first else { return }
        let geometry = NotchGeometry(screen: screen)
        let previous = state.alert
        let mode = Self.nextMode(previous: previous, previousMode: state.mode, next: alert, replyTarget: state.replyTarget)
        if mode != .reply { endReply() }
        let panel = self.panel ?? makePanel()
        let opening = previous == nil || !panel.isVisible
        state.geometry = geometry
        if opening {
            state.alert = alert
            state.mode = mode
            state.expanded = false
            panel.setFrame(geometry.panelFrame(mode, alert: alert), display: true)
            panel.orderFrontRegardless()
            panel.ignoresMouseEvents = false
            // Let the collapsed shape draw once at notch size, then grow.
            DispatchQueue.main.async { [weak self] in self?.withMotion { self?.state.expanded = true } }
        } else {
            resize(to: geometry.panelFrame(mode, alert: alert))
            withMotion { state.alert = alert; state.mode = mode }
        }
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

    private func setMode(_ mode: NotchState.Mode) {
        guard panel != nil, state.mode != mode else { return }
        resize(to: state.geometry.panelFrame(mode, alert: state.alert))
        withMotion { state.mode = mode }
    }

    /// Grows at once; shrinks after the shape has animated smaller, so nothing is clipped.
    private func resize(to frame: CGRect) {
        guard let panel else { return }
        if frame.height >= panel.frame.height && frame.width >= panel.frame.width {
            panel.setFrame(frame, display: true)
        } else {
            Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, let panel, let alert = self.state.alert,
                      self.state.geometry.panelFrame(self.state.mode, alert: alert) == frame else { return }
                panel.setFrame(frame, display: true)
            }
        }
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
        endReply()
        // A hidden panel never sends the pointer's exit.
        hovering = false
        panel?.orderOut(nil)
        state.alert = nil
        state.expanded = false
    }

    private func close() {
        timerTask?.cancel()
        menuTask?.cancel()
        endReply()
        hovering = false
        guard state.alert != nil else { panel?.orderOut(nil); return }
        panel?.ignoresMouseEvents = true
        withMotion { state.expanded = false }
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, self.queue.presentation == nil else { return }
            self.state.alert = nil
            self.state.mode = .card
            self.panel?.orderOut(nil)
        }
    }

    // MARK: Timers

    private func scheduleTimers() {
        timerTask?.cancel()
        guard !hovering, available else { return }
        queue.startTimers(now: Date())
        guard let deadline = queue.nextDeadline else { return }
        timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, deadline.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let gone = self.queue.expire(now: Date())
            self.remember(gone)
            for alert in gone { self.onAction?(alert.id, NotchAlert.dismissAction) }
            self.refresh()
        }
    }

    /// While anything waits, checks once a second for a menu under the notch. Stops when the queue is empty.
    private func watchMenus() {
        guard menuTask == nil || menuTask?.isCancelled == true else { return }
        menuTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.queue.isEmpty, let screen = NSScreen.screens.first else { break }
                let area = NotchGeometry(screen: screen).panelFrame(.detail, alert: self.queue.presentation)
                let open = NotchMenuGuard.menuOpen(over: area, screen: screen.frame)
                if open != self.menuOpen {
                    self.menuOpen = open
                    self.refresh()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self?.menuTask = nil
            self?.menuOpen = false
        }
    }

    private func withMotion(_ change: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { change() }
        else { withAnimation(.spring(response: 0.42, dampingFraction: 0.78), change) }
    }
}
