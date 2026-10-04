import Foundation

/// When the runner holds its "keep awake on power" assertion, and when it renews it. Pure, so it can be tested;
/// the runner does the IOKit calls. The assertion only stops idle system sleep: the display still sleeps and
/// locks, and lid close, the Apple menu's Sleep, low battery, and shutdown still win. Missed times catch up on
/// wake or login through each automation's own catch-up policy.
public enum KeepAwakePolicy {
    public enum PowerSource: Equatable, Sendable { case ac, battery, unknown }

    /// The OS releases the assertion by itself after this long, so a stuck runner cannot keep the Mac awake.
    public static let assertionTimeout: TimeInterval = 300
    /// A held assertion is replaced this often, well before its timeout.
    public static let renewInterval: TimeInterval = 120

    public enum Step: Equatable, Sendable { case none, create, renew, release }

    /// True only when the setting is on, the Mac is on power, the runner is not stopping, and at least one
    /// automation is on and has a future scheduled time. Unknown power counts as battery.
    public static func wanted(settings: AutomationSettings, automations: [Automation], power: PowerSource,
                              shuttingDown: Bool, now: Date) -> Bool {
        guard settings.keepAwakeOnPower, power == .ac, !shuttingDown else { return false }
        return automations.contains { hasScheduledWork($0, now: now) }
    }

    /// An automation that is on and will start again by itself. Manual, paused, and finished one-time ones do not count.
    public static func hasScheduledWork(_ automation: Automation, now: Date) -> Bool {
        guard automation.enabled else { return false }
        switch automation.schedule.rule {
        case .manual: return false
        case .once(let date): return date > now
        case .rrule: return Scheduler.nextRun(automation, lastCovered: nil, now: now) != nil
        }
    }

    /// What to do with the assertion this tick. `heldSince` is when the current one was made, or nil.
    public static func step(wanted: Bool, heldSince: Date?, now: Date) -> Step {
        switch (wanted, heldSince) {
        case (false, nil): return .none
        case (false, _?): return .release
        case (true, nil): return .create
        case (true, let since?):
            // A clock that moved back also renews, so the timeout never runs out under a held assertion.
            let age = now.timeIntervalSince(since)
            return age >= renewInterval || age < 0 ? .renew : .none
        }
    }

    /// After a failed renew, the old assertion is kept only while it is well inside its OS timeout, so the next
    /// tick can try again. After that, or when the clock moved back, it is dropped and the next tick makes a new one.
    public static func keepsOldAfterFailedRenew(heldSince: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(heldSince)
        return age >= 0 && age < assertionTimeout - 60
    }
}
