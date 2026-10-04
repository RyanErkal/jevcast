import Foundation

/// A plain explanation for a finished run that did not succeed, when its cause is known. Display only:
/// the run's state, error, and files stay as saved.
public struct FailureExplanation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The same input gives the same result; a person must act before a run can succeed.
        case needsReview
        /// The runner stopped during the run (shutdown, restart, logout, or a runner restart). Not the job's fault.
        case interrupted
    }
    public var kind: Kind
    public var title: String
    public var message: String
    /// False when running again cannot change the result by itself.
    public var retryHelps: Bool
}

public enum FailureExplainer {
    public static func explain(_ run: RunRecord, catchUp: CatchUp?) -> FailureExplanation? {
        switch run.state {
        case .failed:
            let text = run.error ?? run.summary
            if let counts = divergence(in: text) {
                return FailureExplanation(
                    kind: .needsReview, title: "Needs review: Git branches diverged",
                    message: "The local branch and its remote each have commits the other lacks\(counts). The script stopped "
                        + "instead of choosing a side. Running again gives the same result until someone reconciles the "
                        + "branches. Jevcast does not change Git.",
                    retryHelps: false)
            }
            return nil
        case .interrupted:
            // A program that could not be confirmed stopped still needs attention; keep the full warning.
            guard run.orphanPGID == nil else { return nil }
            let next: String
            switch catchUp {
            case .runOnce?: next = "After the Mac wakes or you log in, the newest missed time runs once."
            case .skip?: next = "Missed times are skipped. The next scheduled time runs as usual."
            case nil: next = "The next scheduled time runs as usual."
            }
            return FailureExplanation(
                kind: .interrupted, title: "Interrupted",
                message: "The runner stopped during this run. This happens when the Mac shuts down or restarts, you log out, "
                    + "or the runner restarts. Check the saved output before running it again. " + next,
                retryHelps: true)
        default:
            return nil
        }
    }

    /// " (42 ahead, 42 behind)" for a Git divergence message, "" when it has no counts, nil when it is not one.
    static func divergence(in text: String) -> String? {
        let lower = text.lowercased()
        guard lower.contains("diverged from") || (lower.contains("have diverged") && lower.contains("branch")) else { return nil }
        guard let open = lower.range(of: "("), let close = lower.range(of: ")", range: open.upperBound..<lower.endIndex) else { return "" }
        let inside = lower[open.upperBound..<close.lowerBound]
        guard inside.contains("ahead"), inside.contains("behind"), inside.count <= 40 else { return "" }
        return " (" + inside + ")"
    }
}

/// Runs in a list, with a failure that repeats the one before it folded into one entry. A streak is a run of
/// back-to-back finished runs of one automation that failed or were interrupted with the same error
/// (`FailureDedupe.key`). Any other run of that automation between them ends the streak.
public struct RunStreak: Identifiable, Sendable {
    /// The newest run in the streak; the entry shows it.
    public var latest: RunRecord
    /// The older runs of the streak in the list, newest first.
    public var earlier: [RunRecord]
    public var id: String { latest.id }
    public var count: Int { earlier.count + 1 }
    public var runs: [RunRecord] { [latest] + earlier }
    /// When the oldest listed run of the streak started.
    public var since: Date { (earlier.last ?? latest).started ?? (earlier.last ?? latest).queued }
}

public enum RunStreaks {
    /// `list` is the runs to show, newest first. `history` holds each automation's runs, newest first; it decides
    /// which runs are back to back, so a success hidden from `list` (as in Failed Recently) still ends a streak.
    public static func collapse(_ list: [RunRecord], history: [String: [RunRecord]]) -> [RunStreak] {
        var head: [String: String] = [:]
        for runs in history.values {
            var current: RunRecord?
            for run in runs {
                if let c = current, joins(run, c) { head[run.id] = c.id; continue }
                current = foldable(run) ? run : nil
                head[run.id] = run.id
            }
        }
        var streaks: [RunStreak] = []
        var index: [String: Int] = [:]
        for run in list {
            let key = run.automationID + "/" + (head[run.id] ?? run.id)
            if let i = index[key] { streaks[i].earlier.append(run); continue }
            index[key] = streaks.count
            streaks.append(RunStreak(latest: run, earlier: []))
        }
        return streaks
    }

    static func foldable(_ run: RunRecord) -> Bool { [.failed, .interrupted].contains(run.state) }

    static func joins(_ run: RunRecord, _ newer: RunRecord) -> Bool {
        foldable(run) && run.state == newer.state && FailureDedupe.key(run) == FailureDedupe.key(newer)
    }
}
