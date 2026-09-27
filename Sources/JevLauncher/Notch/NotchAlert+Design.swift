import Foundation

/// What the notch views draw. Views read only this, so new `NotchAlert` fields
/// reach the design through `init(_:)` and nowhere else.
struct NotchPresentation: Equatable {
    enum Phase: Equatable { case running, question, approval, success, failure, info }

    var phase: Phase
    var symbol: String
    var title: String
    var message: String
    /// A short second fact: approval counts, a failure reason, or a run's latest activity.
    var detail: String?
    /// 0...1 for a known amount of work; nil draws an indeterminate ring while running.
    var progress: Double?
    /// When the run started, for the elapsed time while running.
    var startedAt: Date?
    /// Alerts in this stack. Above 1 shows a "+N" badge.
    var stackCount: Int = 1
    /// A question's answers. Each sends `NotchAlert.choiceAction(index)`.
    var choices: [NotchAlert.Action]
    /// At most three are drawn.
    var actions: [NotchAlert.Action]

    init(phase: Phase, symbol: String, title: String, message: String, detail: String? = nil, progress: Double? = nil,
         startedAt: Date? = nil, stackCount: Int = 1, choices: [NotchAlert.Action] = [], actions: [NotchAlert.Action]) {
        self.phase = phase; self.symbol = symbol; self.title = title; self.message = message; self.detail = detail
        self.progress = progress; self.startedAt = startedAt; self.stackCount = stackCount; self.choices = choices
        self.actions = actions
    }

    init(_ alert: NotchAlert) {
        let phase: Phase
        switch alert.kind {
        case .running: phase = .running
        case .question: phase = .question
        case .approval: phase = .approval
        case .success: phase = .success
        case .failure: phase = .failure
        case .info: phase = .info
        }
        var message = alert.message
        var detail = alert.detail
        // What an approval would change is the message; the builder already puts it there.
        if let counts = alert.counts, message != counts.summary {
            if detail == nil { detail = counts.summary } else { message = counts.summary }
        }
        var actions = alert.actions
        if alert.allowsReply && !actions.contains(where: { $0.id == NotchAlert.replyAction }) {
            actions.insert(.init("Reply…", id: NotchAlert.replyAction), at: 0)
        }
        let choices = alert.choices.prefix(4).enumerated().map { index, text in
            NotchAlert.Action(text, id: NotchAlert.choiceAction(index), role: .normal)
        }
        self.init(phase: phase, symbol: alert.symbol, title: alert.title, message: message, detail: detail,
                  progress: alert.progress.map { min(1, max(0, $0)) }, startedAt: alert.started,
                  stackCount: max(1, alert.stackCount), choices: Array(choices), actions: actions)
    }

    var visibleActions: [NotchAlert.Action] { Array(actions.prefix(3)) }
    /// Needs the user now: the icon pulses.
    var wantsAttention: Bool { phase == .question || phase == .approval }
    /// Success and info fit on one line with their action inline.
    var isBrief: Bool { (phase == .success || phase == .info) && detail == nil && actions.count <= 1 && stackCount == 1 }
    /// Up to two buttons for a row in a stack list: the primary one, then Later or the next one.
    var rowActions: [NotchAlert.Action] {
        let usable = actions.filter { $0.id != NotchAlert.expandAction }
        guard let first = usable.first(where: \.primary) ?? usable.first else { return [] }
        let second = usable.first { $0.id == "later" && $0 != first } ?? usable.first { $0 != first }
        return [first] + (second.map { [$0] } ?? [])
    }
}

extension NotchAlert {
    var presentation: NotchPresentation { NotchPresentation(self) }
}
