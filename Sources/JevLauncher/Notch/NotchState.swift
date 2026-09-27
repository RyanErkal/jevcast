import AppKit
import SwiftUI

/// What the notch view draws. The controller sets every field; views call the methods below and nothing else.
@MainActor
final class NotchState: ObservableObject {
    enum Mode: Equatable {
        /// A running indicator beside the notch.
        case pill
        /// One alert or a collapsed stack.
        case card
        /// A stack as a list, or a running indicator with its latest activity and Cancel.
        case detail
        /// The card with a text field for an answer. The panel takes keyboard focus only in this mode.
        case reply
    }

    /// The alert on screen. For a stack, `alert.stack` holds the rows.
    @Published var alert: NotchAlert?
    /// True once the shape has grown out of the notch. False while it opens or closes.
    @Published var expanded = false
    @Published var mode: Mode = .card
    @Published var geometry = NotchGeometry(screenFrame: .zero, notchWidth: 0, notchHeight: 0)
    /// The alert the reply field answers. Nil unless `mode == .reply`.
    @Published var replyTarget: String?

    func present(_ alert: NotchAlert, mode: Mode) {
        self.alert = alert
        self.mode = mode
        expanded = true
    }

    func endReply() {
        replyTarget = nil
        if mode == .reply { mode = alert.map(NotchAlertController.restingMode) ?? .card }
    }

    var bodyHeight: CGFloat { geometry.bodyHeight(mode, alert: alert) }
    var width: CGFloat { geometry.width(mode) }

    var performHandler: ((String?, String) -> Void)?
    var hoverHandler: ((Bool) -> Void)?

    /// Runs an action. `alertID` is a row of a stack; nil means the alert on screen.
    func perform(_ action: String, on alertID: String? = nil) { performHandler?(alertID, action) }
    /// Sends typed text as the answer, for the reply target.
    func submitReply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .reply, let replyTarget, !trimmed.isEmpty else { return }
        performHandler?(replyTarget, NotchAlert.replyText(trimmed))
    }
    func cancelReply() { performHandler?(replyTarget, NotchAlert.collapseAction) }
    func hover(_ inside: Bool) { hoverHandler?(inside) }
}

final class NotchPanel: NSPanel {
    /// True only while the reply field is open, after the user clicked Reply.
    var allowsKey = false

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
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
