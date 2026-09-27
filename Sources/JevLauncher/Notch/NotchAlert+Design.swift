import Foundation

/// What the notch views draw. Views read only this, so new `NotchAlert` fields
/// reach the design through `init(_:)` and nowhere else.
struct NotchPresentation: Equatable {
    enum Phase: Equatable { case running, question, approval, success, failure, info }

    var phase: Phase
    var symbol: String
    var title: String
    var message: String
    /// Short counts, for example "12 files to move · 3 to Trash".
    var detail: String?
    /// 0...1 for a known amount of work; nil draws an indeterminate ring while running.
    var progress: Double?
    /// When the run started, for the elapsed time while running.
    var startedAt: Date?
    /// Alerts merged into this one. Above 1 shows a "+N" badge.
    var stackCount: Int = 1
    /// At most three are drawn.
    var actions: [NotchAlert.Action]

    init(phase: Phase, symbol: String, title: String, message: String, detail: String? = nil, progress: Double? = nil,
         startedAt: Date? = nil, stackCount: Int = 1, actions: [NotchAlert.Action]) {
        self.phase = phase; self.symbol = symbol; self.title = title; self.message = message; self.detail = detail
        self.progress = progress; self.startedAt = startedAt; self.stackCount = stackCount; self.actions = actions
    }

    /// Maps an alert to a presentation. Hook new alert fields in here
    /// (detail, progress, startedAt, stack count, a running kind).
    init(_ alert: NotchAlert) {
        let ids = Set(alert.actions.map(\.id))
        let phase: Phase
        switch alert.tone {
        case .failure: phase = .failure
        case .success: phase = .success
        case .info: phase = .info
        case .attention: phase = ids.contains("answer") ? .question : .approval
        }
        self.init(phase: phase, symbol: alert.symbol, title: alert.title, message: alert.message, actions: alert.actions)
    }

    var visibleActions: [NotchAlert.Action] { Array(actions.prefix(3)) }
    /// Needs the user now: the icon pulses.
    var wantsAttention: Bool { phase == .question || phase == .approval }
    /// Success and info fit on one line with their action inline.
    var isBrief: Bool { (phase == .success || phase == .info) && detail == nil && actions.count <= 1 }
}

extension NotchAlert {
    var presentation: NotchPresentation { NotchPresentation(self) }
}
