import AppKit
import SwiftUI

/// One alert for the notch panel. Automations use it only when they need the user.
struct NotchAlert: Identifiable, Equatable {
    struct Action: Equatable {
        let title: String
        let primary: Bool
        let id: String
        init(_ title: String, id: String, primary: Bool = false) { self.title = title; self.id = id; self.primary = primary }
    }
    enum Tone: Equatable { case attention, failure, success, info }
    let id: String
    let symbol: String
    let title: String
    let message: String
    let tone: Tone
    let actions: [Action]
}

/// Shows alerts as a black card that grows out of the MacBook notch, one at a time.
/// On a screen without a notch the card drops from the top centre as a pill.
/// The panel never takes keyboard focus; a button click calls `onAction`.
@MainActor
final class NotchAlertController {
    static let shared = NotchAlertController()
    /// Called with the alert ID and the action ID. "dismiss" is sent when it closes on its own.
    var onAction: ((String, String) -> Void)?
    /// Seconds before an alert closes when the pointer is not over it.
    var visibleSeconds: TimeInterval = 6

    private var queue: [NotchAlert] = []
    private var panel: NotchPanel?
    private let state = NotchState()
    private var hideTask: Task<Void, Never>?
    private var session: NotchSession?
    private var sessionAvailable = NotchSession.isAvailable

    init() {
        session = NotchSession { [weak self] available in
            guard let self else { return }
            self.sessionAvailable = available
            if available { self.next() }
            else {
                self.hideTask?.cancel()
                if let alert = self.state.alert { self.queue.insert(alert, at: 0) }
                self.state.alert = nil
                self.panel?.orderOut(nil)
            }
        }
    }

    func show(_ alert: NotchAlert) {
        if state.alert?.id == alert.id || queue.contains(where: { $0.id == alert.id }) { return }
        queue.append(alert)
        if state.alert == nil { next() }
    }

    /// Removes an alert that no longer applies, for example after the user approved in another window.
    func withdraw(id: String) {
        queue.removeAll { $0.id == id }
        if state.alert?.id == id { close(sendDismiss: false) }
    }

    private func next() {
        guard sessionAvailable, state.alert == nil, !queue.isEmpty else { return }
        var alert = queue.removeFirst()
        // A burst becomes one alert, so several failures do not stack up.
        if !queue.isEmpty {
            let count = queue.count + 1
            alert = NotchAlert(id: "merged-" + alert.id, symbol: "bell.badge", title: "\(count) automations need you",
                               message: "Open Automations to see them.", tone: .attention,
                               actions: [.init("Open", id: "open", primary: true), .init("Later", id: "later")])
            queue.removeAll()
        }
        guard let screen = NSScreen.screens.first else { return }
        let geometry = NotchGeometry(screen: screen)
        let panel = self.panel ?? NotchPanel()
        self.panel = panel
        state.geometry = geometry
        state.alert = alert
        state.expanded = false
        panel.contentView = NSHostingView(rootView: NotchAlertView(state: state) { [weak self] action in
            guard let self else { return }
            self.onAction?(alert.id, action)
            self.close(sendDismiss: false)
        } hover: { [weak self] inside in
            inside ? self?.hideTask?.cancel() : self?.scheduleHide(alert.id)
        })
        panel.setFrame(geometry.panelFrame, display: true)
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = false
        // Let the collapsed shape draw once at notch size, then grow.
        DispatchQueue.main.async { [weak self] in self?.withMotion { self?.state.expanded = true } }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "\(alert.title). \(alert.message)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        scheduleHide(alert.id)
    }

    private func scheduleHide(_ id: String) {
        hideTask?.cancel()
        let seconds = visibleSeconds
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, self?.state.alert?.id == id else { return }
            self?.close(sendDismiss: true)
        }
    }

    private func close(sendDismiss: Bool) {
        hideTask?.cancel()
        guard let alert = state.alert else { return }
        if sendDismiss { onAction?(alert.id, "dismiss") }
        panel?.ignoresMouseEvents = true
        withMotion { state.expanded = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.state.alert?.id == alert.id else { return }
            self.state.alert = nil
            self.panel?.orderOut(nil)
            self.next()
        }
    }

    private func withMotion(_ change: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { change() }
        else { withAnimation(.spring(response: 0.42, dampingFraction: 0.78), change) }
    }
}

/// Where the notch is. Width 0 means the screen has none.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    static let cardWidth: CGFloat = 380
    static let cardBody: CGFloat = 92

    init(screenFrame: CGRect, notchWidth: CGFloat, notchHeight: CGFloat) {
        self.screenFrame = screenFrame; self.notchWidth = notchWidth; self.notchHeight = notchHeight
    }

    init(screen: NSScreen) {
        var width: CGFloat = 0
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = max(0, screen.frame.width - left.width - right.width)
        }
        self.init(screenFrame: screen.frame, notchWidth: width, notchHeight: width > 0 ? screen.safeAreaInsets.top : 0)
    }

    var hasNotch: Bool { notchWidth > 0 }
    /// The panel covers the notch and the card below it, and nothing else, so clicks elsewhere pass through.
    var panelFrame: CGRect {
        let width = max(Self.cardWidth, notchWidth) + 24
        let height = notchHeight + Self.cardBody + (hasNotch ? 0 : 10) + 24
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var alert: NotchAlert?
    @Published var expanded = false
    @Published var geometry = NotchGeometry(screenFrame: .zero, notchWidth: 0, notchHeight: 0)
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        // Above the menu bar, so the card can join the notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false; isReleasedWhenClosed = false; isMovable = false
        animationBehavior = .none
        title = "Jevcast alert"
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
