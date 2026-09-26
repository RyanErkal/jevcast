import Foundation

/// A daily quiet period in local time. `start == end` means no quiet time.
public struct QuietHours: Equatable, Sendable {
    /// Minutes after local midnight, 0..<1440.
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) {
        self.start = ((start % 1440) + 1440) % 1440; self.end = ((end % 1440) + 1440) % 1440
    }

    /// True when `date` falls in the quiet period. A period may cross midnight, for example 22:00 to 07:00.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard start != end else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }

    /// The first moment after `date` when the quiet period is over. Nil when `date` is not quiet.
    public func end(after date: Date, calendar: Calendar) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        let day = calendar.startOfDay(for: date)
        var comps = DateComponents(); comps.hour = end / 60; comps.minute = end % 60
        // Today at the end time, or tomorrow when that has passed. DST gaps move to the next valid time.
        for offset in 0...2 {
            guard let base = calendar.date(byAdding: .day, value: offset, to: day),
                  let candidate = calendar.nextDate(after: base.addingTimeInterval(-1), matching: comps, matchingPolicy: .nextTime),
                  candidate > date else { continue }
            return candidate
        }
        return nil
    }
}

/// App-level alert switches, from Settings › Automations › Alerts.
public struct AlertSettings: Equatable, Sendable {
    public var enabled: Bool
    /// Failure alerts at all. Each automation's `alertOnFailure` still applies.
    public var failures: Bool
    public var quietHours: QuietHours?
    public var hideNames: Bool
    public init(enabled: Bool = true, failures: Bool = true, quietHours: QuietHours? = nil, hideNames: Bool = false) {
        self.enabled = enabled; self.failures = failures; self.quietHours = quietHours; self.hideNames = hideNames
    }
}

/// Whether a run should show a notch alert now. Pure: the app shows it and marks `alerted`.
public enum AlertDecision: Equatable, Sendable {
    case show
    /// Quiet hours: check again at this time.
    case wait(until: Date)
    case skip

    /// Runs that ended longer ago than this never alert, so a first launch or turning alerts on does not replay old history.
    public static let maxAge: TimeInterval = 24 * 3600

    public static func decide(_ run: RunRecord, policy: Policy?, settings: AlertSettings, now: Date,
                              calendar: Calendar = .current) -> AlertDecision {
        guard settings.enabled, !run.alerted else { return .skip }
        switch run.state {
        case .needsInput, .needsApproval: break
        case .failed: guard settings.failures, policy?.alertOnFailure ?? true else { return .skip }
        case .succeeded: return .skip
        default: return .skip
        }
        let when = run.finished ?? run.started ?? run.queued
        guard now.timeIntervalSince(when) <= maxAge else { return .skip }
        if let quiet = settings.quietHours, let end = quiet.end(after: now, calendar: calendar) { return .wait(until: end) }
        return .show
    }
}

/// The words on a notch alert. Hidden names keep automation and file names off the screen.
public struct AlertText: Equatable, Sendable {
    public var title: String
    public var message: String

    public static func make(_ run: RunRecord, name: String, hideNames: Bool) -> AlertText {
        if hideNames {
            let message: String
            switch run.state {
            case .needsInput: message = "It has a question for you."
            case .needsApproval: message = "It has changes for you to review."
            case .failed: message = "It failed."
            case .succeeded: message = "It finished."
            default: message = run.state.title
            }
            return AlertText(title: "An automation", message: message)
        }
        let summary = run.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = run.state == .failed ? (run.error.map { "Failed: " + $0 } ?? run.state.title) : run.state.title
        return AlertText(title: name.isEmpty ? run.automationName : name,
                         message: String((summary.isEmpty ? fallback : summary).prefix(160)))
    }
}
