import Foundation

/// What the notch views draw. Views read only this, so new `NotchAlert` fields
/// reach the design through `init(_:)` and nowhere else.
struct NotchPresentation: Equatable {
    enum Phase: Equatable { case running, question, approval, review, success, failure, info }

    /// One automation's look: its symbol and accent. A running stack shows a few of these side by side.
    struct Identity: Equatable, Hashable {
        var symbol: String
        var accent: String?
    }

    /// The most automation icons a running stack draws. The count beside them always shows the total.
    static let maxIdentities = 3

    var phase: Phase
    var symbol: String
    /// An `AutomationAccent` name. It colours the icon only; the state shows in a separate badge or ring.
    var accent: String?
    var title: String
    var message: String
    /// A short second fact: approval counts, a failure reason, or a run's last finished stage.
    var detail: String?
    /// 0...1 for a known amount of work; nil draws an indeterminate ring while running.
    var progress: Double?
    /// When the run started, for the one elapsed time in the open running card.
    var startedAt: Date?
    var retry: NotchAlert.Retry?
    var attempt: Int?
    var lastSuccess: Date?
    /// Alerts in this stack. Above 1 shows a count.
    var stackCount: Int = 1
    /// A running stack's distinct looks, in its order, at most `maxIdentities`.
    var identities: [Identity] = []
    /// A question's answers. Each sends `NotchAlert.choiceAction(index)`.
    var choices: [NotchAlert.Action]
    /// Two are drawn as buttons; the rest, and every `menuOnly` one, go in an overflow menu.
    var actions: [NotchAlert.Action]

    init(phase: Phase, symbol: String, accent: String? = nil, title: String, message: String, detail: String? = nil,
         progress: Double? = nil, startedAt: Date? = nil, retry: NotchAlert.Retry? = nil, attempt: Int? = nil,
         lastSuccess: Date? = nil, stackCount: Int = 1, identities: [Identity] = [], choices: [NotchAlert.Action] = [],
         actions: [NotchAlert.Action]) {
        self.phase = phase; self.symbol = symbol; self.accent = accent; self.title = title; self.message = message
        self.detail = detail; self.progress = progress; self.startedAt = startedAt; self.retry = retry
        self.attempt = attempt; self.lastSuccess = lastSuccess; self.stackCount = stackCount; self.identities = identities
        self.choices = choices; self.actions = actions
    }

    init(_ alert: NotchAlert) {
        let phase: Phase
        switch alert.kind {
        case .running: phase = .running
        case .question: phase = .question
        case .approval: phase = .approval
        case .review: phase = .review
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
        self.init(phase: phase, symbol: alert.symbol, accent: alert.accent, title: alert.title, message: message, detail: detail,
                  progress: alert.progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }, startedAt: alert.started,
                  retry: alert.retry, attempt: alert.attempt, lastSuccess: alert.lastSuccess,
                  stackCount: max(1, alert.stackCount), identities: Self.identities(alert.stack),
                  choices: Array(choices), actions: actions)
    }

    /// Distinct looks of the running members, first come first, so the pill never cycles or reorders.
    static func identities(_ members: [NotchAlert]) -> [Identity] {
        var seen: [Identity] = []
        for member in members where member.kind == .running {
            let look = Identity(symbol: member.symbol, accent: member.accent)
            if !seen.contains(look) { seen.append(look) }
            if seen.count == maxIdentities { break }
        }
        return seen
    }

    var visibleActions: [NotchAlert.Action] { Array(actions.filter { !$0.menuOnly }.prefix(2)) }
    var overflowActions: [NotchAlert.Action] {
        Array(actions.filter { !$0.menuOnly }.dropFirst(2)) + actions.filter(\.menuOnly)
    }
    /// Needs the user now: the icon pulses once on arrival.
    var wantsAttention: Bool { phase == .question || phase == .approval || phase == .review }
    /// Success and info fit on one line with their action inline.
    var isBrief: Bool { (phase == .success || phase == .info) && detail == nil && actions.count <= 1 && stackCount == 1 }
    /// Two or more automations running together.
    var isRunningStack: Bool { phase == .running && stackCount > 1 }
    /// Up to two buttons for a row in a stack list: the primary one, then Later or the next one. Menu-only actions
    /// go in the row's overflow menu (`rowMenu`).
    var rowActions: [NotchAlert.Action] {
        let usable = actions.filter { $0.id != NotchAlert.expandAction && !$0.menuOnly }
        guard let first = usable.first(where: \.primary) ?? usable.first else { return [] }
        let second = usable.first { $0.id == "later" && $0 != first } ?? usable.first { $0 != first }
        return [first] + (second.map { [$0] } ?? [])
    }
    var rowMenu: [NotchAlert.Action] { actions.filter(\.menuOnly) }

    /// The running card's second line: the retry, or the last finished stage, or plain "Running", then the attempt when
    /// it is not the first. It leads with what happens now, so a narrow row cuts the attempt first. Never a placeholder.
    func runningLine(now: Date) -> String {
        if let retry {
            let next = retry.at.flatMap { $0 > now ? "Retrying in " + NotchStyle.clock($0.timeIntervalSince(now)) : nil }
            return (next ?? "Retrying automatically") + " · attempt \(retry.attempt) failed"
        }
        let line = detail ?? message
        return attempt.map { line + " · attempt \($0)" } ?? line
    }
}

extension NotchAlert {
    var presentation: NotchPresentation { NotchPresentation(self) }
}
