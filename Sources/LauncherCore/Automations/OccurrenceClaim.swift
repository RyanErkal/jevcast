import Foundation

/// Claims scheduled occurrences so each one runs at most once, even across a crash or a failed write.
///
/// Order: the queued run is written first under an ID derived from the automation and the occurrence
/// (`RunID.occurrence`), then `state.json` advances. A crash between the two leaves a run whose ID the next
/// tick finds, so the occurrence is not queued again. A failed state write is harmless for the same reason.
public struct OccurrenceClaim {
    public enum Result: Equatable, Sendable {
        /// Nothing is due.
        case nothing
        /// Due occurrences were consumed without a run (missed with `.skip`, or the automation was busy).
        case skipped
        /// A new run was written. The caller starts it when its state is still `.queued`.
        case queued(RunRecord)
        /// A run for this occurrence already existed; none was added.
        case alreadyClaimed(String)
        /// The run could not be written. State was not advanced, so the next tick tries again.
        case failed(String)
    }

    public let store: AutomationStore

    public init(store: AutomationStore) { self.store = store }

    /// `prepare` sets owner fields or blocks the run before its first write.
    public func claimDue(_ automation: Automation, now: Date, busy: Bool,
                         prepare: (inout RunRecord) -> Void = { _ in }) -> Result {
        var state = store.state(for: automation.id)
        let covered = Self.effectiveLastCovered(state.lastCovered, runs: store.runs(for: automation.id, limit: 50))
        let due = Scheduler.due(automation, lastCovered: covered, now: now)
        guard let through = due.coveredThrough else {
            // A run found on disk covers more than state says (a crash before the state write): catch state up.
            if covered != state.lastCovered, let covered {
                state.lastCovered = covered
                try? store.saveState(state, for: automation.id)
            }
            return .nothing
        }
        var result = Result.skipped
        if let occurrence = due.runs.first, !busy {
            let id = RunID.occurrence(automationID: automation.id, date: occurrence)
            var run = RunRecord(id: id, automation: automation, trigger: .schedule, occurrence: occurrence, queued: now)
            prepare(&run)
            do {
                result = try store.createRun(run) ? .queued(run) : .alreadyClaimed(id)
            } catch {
                return .failed("\(error)")
            }
            state.lastRunID = id
        }
        state.lastCovered = through
        // Even when this fails, the run's fixed ID keeps the occurrence from being queued twice.
        try? store.saveState(state, for: automation.id)
        return result
    }

    /// The newer of the state file's date and the newest occurrence any run covers (only scheduled runs have one).
    static func effectiveLastCovered(_ saved: Date?, runs: [RunRecord]) -> Date? {
        let fromRuns = runs.compactMap(\.occurrence).max()
        switch (saved, fromRuns) {
        case let (a?, b?): return max(a, b)
        case let (a, b): return a ?? b
        }
    }
}
