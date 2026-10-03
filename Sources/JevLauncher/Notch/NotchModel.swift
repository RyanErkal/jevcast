import Foundation
import LauncherCore

/// One alert for the notch panel. Automations use it only when they need the user, or for the opt-in live indicator.
/// Views read these fields; they never decide what an action does.
struct NotchAlert: Identifiable, Equatable {
    enum Kind: String, Equatable, CaseIterable {
        /// `review`: a finished run that stopped on something only the user can settle. It is never shown as done.
        case running, question, approval, review, success, failure, info
    }
    enum Tone: Equatable { case attention, failure, success, info }

    struct Action: Equatable, Identifiable {
        enum Role: Equatable { case primary, destructive, normal }
        let id: String
        let title: String
        let role: Role
        /// Shown only in the overflow menu, such as Cancel on a running card.
        var menuOnly = false
        var primary: Bool { role == .primary }
        init(_ title: String, id: String, role: Role, menuOnly: Bool = false) {
            self.title = title; self.id = id; self.role = role; self.menuOnly = menuOnly
        }
        init(_ title: String, id: String, primary: Bool = false) { self.init(title, id: id, role: primary ? .primary : .normal) }
    }

    /// A retry the runner has scheduled. Each fact is shown only when it is known.
    struct Retry: Equatable {
        /// The attempt that failed. The next one is `attempt + 1`.
        var attempt: Int
        /// When the next attempt starts. Run records do not carry it, so only demo fixtures set it.
        var at: Date?
    }

    /// What an approval would change, from the checked proposal.
    struct ApprovalCounts: Equatable {
        var moves = 0, renames = 0, folders = 0, trash = 0, tags = 0
        /// Items the check refused. They are never applied.
        var refused = 0
        var total: Int { moves + renames + folders + trash + tags }
        /// "12 moves, 3 to Trash". Refused items are named last.
        var summary: String {
            var parts: [String] = []
            func add(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") } }
            add(moves, "move", "moves"); add(renames, "rename", "renames"); add(folders, "new folder", "new folders")
            if trash > 0 { parts.append("\(trash) to Trash") }
            add(tags, "tag", "tags"); add(refused, "refused", "refused")
            return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
        }
    }

    let id: String
    var kind: Kind
    var symbol: String
    /// The automation's `AutomationAccent` name. It colours the icon only; nil keeps the plain icon, tinted by state.
    var accent: String?
    var title: String
    var message: String
    /// A second line, for example the latest activity of a running automation. Shown when there is room.
    var detail: String?
    /// 0...1 when known. Nil shows an indeterminate state.
    var progress: Double?
    /// When the work started, for an elapsed-time label.
    var started: Date?
    /// Set while the run waits for a scheduled retry.
    var retry: Retry?
    /// The attempt running now, from the second one on. Nil for a first attempt.
    var attempt: Int?
    /// The automation's last finished success, from its run records.
    var lastSuccess: Date?
    var tone: Tone
    var actions: [Action]
    /// Answers a question offers. A view shows each as a button that sends `NotchAlert.choiceAction(index)`.
    var choices: [String]
    /// True when the view may offer "Reply…" (`NotchAlert.replyAction`), which opens a text field.
    var allowsReply: Bool
    var approvalManifest: ProposalManifest?
    var counts: ApprovalCounts?
    var automationID: String?
    var runID: String?
    /// For a stack: the alerts it holds, highest priority first. Empty for a single alert.
    var stack: [NotchAlert]

    var stackCount: Int { stack.count }
    var isStack: Bool { !stack.isEmpty }

    init(id: String, kind: Kind, symbol: String, accent: String? = nil, title: String, message: String, detail: String? = nil,
         progress: Double? = nil, started: Date? = nil, retry: Retry? = nil, lastSuccess: Date? = nil, tone: Tone? = nil,
         actions: [Action] = [], choices: [String] = [], allowsReply: Bool = false, counts: ApprovalCounts? = nil,
         automationID: String? = nil, runID: String? = nil, stack: [NotchAlert] = []) {
        self.id = id; self.kind = kind; self.symbol = symbol; self.accent = accent; self.title = title; self.message = message
        self.detail = detail; self.progress = progress; self.started = started; self.retry = retry; self.lastSuccess = lastSuccess
        self.tone = tone ?? Self.tone(for: kind)
        self.actions = actions; self.choices = choices; self.allowsReply = allowsReply; self.counts = counts
        self.automationID = automationID; self.runID = runID; self.stack = stack
    }

    /// The original initializer. The kind follows the tone.
    init(id: String, symbol: String, title: String, message: String, tone: Tone, actions: [Action]) {
        let kind: Kind
        switch tone { case .attention: kind = .question; case .failure: kind = .failure; case .success: kind = .success; case .info: kind = .info }
        self.init(id: id, kind: kind, symbol: symbol, title: title, message: message, tone: tone, actions: actions)
    }

    static func tone(for kind: Kind) -> Tone {
        switch kind {
        case .question, .approval, .review: return .attention
        case .failure: return .failure
        case .success: return .success
        case .running, .info: return .info
        }
    }

    // MARK: Action IDs the controller and views share

    /// Opens the run in the Automations window, at its exact automation and run IDs.
    static let detailsAction = "open"
    /// Grows a stack into its list, or a running pill into its detail. Handled by the controller.
    static let expandAction = "expand"
    static let collapseAction = "collapse"
    /// Opens the reply field. Handled by the controller.
    static let replyAction = "reply"
    /// Sent when an alert closes without a button.
    static let dismissAction = "dismiss"
    static func choiceAction(_ index: Int) -> String { "choice:\(index)" }

    /// True when this alert still offers `action`: one of its buttons, a choice or typed answer it accepts, or a close.
    /// A button pressed on an alert that has since changed is checked against this, so it never does something else.
    func offers(_ action: String) -> Bool {
        if action == Self.dismissAction { return true }
        if action.hasPrefix("reply:") { return kind == .question && allowsReply }
        if action.hasPrefix("choice:") { return Int(action.dropFirst(7)).map { choices.prefix(4).indices.contains($0) } ?? false }
        return actions.contains { $0.id == action }
    }
    /// The text the user typed in the reply field.
    static func replyText(_ text: String) -> String { "reply:" + text }
}
