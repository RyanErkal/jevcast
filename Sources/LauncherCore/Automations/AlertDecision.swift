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
    /// The live indicator for long runs. Off by default, because automations stay silent.
    public var liveRunning: Bool
    /// Seconds a failure alert stays up.
    public var failureSeconds: Double
    public init(enabled: Bool = true, failures: Bool = true, quietHours: QuietHours? = nil, hideNames: Bool = false,
                liveRunning: Bool = false, failureSeconds: Double = 8) {
        self.enabled = enabled; self.failures = failures; self.quietHours = quietHours; self.hideNames = hideNames
        self.liveRunning = liveRunning; self.failureSeconds = failureSeconds
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
        guard settings.enabled, !run.alerted, wants(run, policy: policy, failures: settings.failures) else { return .skip }
        let when = run.finished ?? run.started ?? run.queued
        guard now.timeIntervalSince(when) <= maxAge else { return .skip }
        if let quiet = settings.quietHours, let end = quiet.end(after: now, calendar: calendar) { return .wait(until: end) }
        return .show
    }

    /// Whether this run's state calls for an alert at all, before quiet hours and age.
    /// Input and approval always do. Failures and interruptions do when failure alerts are on, once per
    /// distinct error. Successes do only when the automation alerts on success and the run has something
    /// to show; a quiet check (nothing due) never does.
    public static func wants(_ run: RunRecord, policy: Policy?, failures: Bool = true) -> Bool {
        switch run.state {
        case .needsInput, .needsApproval: return true
        case .failed, .interrupted: return failures && (policy?.alertOnFailure ?? true) && run.repeatFailure != true
        case .succeeded: return policy?.alertOnSuccess == true && run.quiet != true
        default: return false
        }
    }

    /// A run shows the live indicator after it has run this long.
    public static let runningDelay: TimeInterval = 10

    /// Runs the live indicator follows: working, or waiting for a retry the runner already scheduled.
    public static let liveStates: Set<RunState> = [.running, .retryWaiting]

    /// Whether a run shows the live running indicator now. Never persisted: it is not a delivery.
    public static func decideRunning(_ run: RunRecord, settings: AlertSettings, now: Date,
                                     calendar: Calendar = .current) -> AlertDecision {
        guard settings.enabled, settings.liveRunning, liveStates.contains(run.state), let started = run.started else { return .skip }
        // A run that claims to have run for over a day is stale, not live.
        guard now.timeIntervalSince(started) <= maxAge else { return .skip }
        if let quiet = settings.quietHours, let end = quiet.end(after: now, calendar: calendar) { return .wait(until: end) }
        let due = started.addingTimeInterval(runningDelay)
        return due > now ? .wait(until: due) : .show
    }
}

/// The words on a notch alert. Hidden names keep automation and file names off the screen: the title becomes
/// the kind of work (`Automation.Kind.category`), and messages use fixed words only.
public struct AlertText: Equatable, Sendable {
    public var title: String
    public var message: String

    public static func make(_ run: RunRecord, name: String, hideNames: Bool,
                            category: String = Automation.Kind.unknownCategory) -> AlertText {
        if hideNames {
            let message: String
            switch run.state {
            case .needsInput: message = "It has a question for you."
            case .needsApproval: message = "It has changes for you to review."
            case .failed: message = run.needsReview ? "It needs your review." : "It failed."
            case .interrupted: message = "It was interrupted."
            case .succeeded: message = run.hasReadyReport ? "A report is ready." : "It finished."
            default: message = run.state.title
            }
            return AlertText(title: category, message: message)
        }
        let summary = run.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback: String
        switch run.state {
        case .failed: fallback = run.error.map { "Failed: " + $0 } ?? run.state.title
        case .interrupted: fallback = run.error.map { "Interrupted: " + $0 } ?? run.state.title
        default: fallback = run.state.title
        }
        return AlertText(title: name.isEmpty ? run.automationName : name,
                         message: String((summary.isEmpty ? fallback : summary).prefix(160)))
    }
}
