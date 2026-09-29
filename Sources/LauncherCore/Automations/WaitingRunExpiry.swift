import Foundation

/// A run that waits for approval longer than `ProposalValidator.maxAge` expires, so it stops blocking
/// later runs of its automation. The runner makes this change. Only `run.json` changes: the proposal,
/// the output, and any journal stay in the run folder.
///
/// Answers have no expiry yet, so a run that waits for an answer is never changed here.
public enum WaitingRunExpiry {
    public static let summary = "Proposal expired after 7 days"

    /// When the proposal was made. The app dates its checked proposal the same way.
    public static func proposalDate(_ run: RunRecord) -> Date { run.finished ?? run.started ?? run.queued }

    /// The expired record for a run whose proposal is too old to approve, or nil.
    public static func expired(_ run: RunRecord, now: Date) -> RunRecord? {
        guard run.state == .needsApproval, now.timeIntervalSince(proposalDate(run)) > ProposalValidator.maxAge else { return nil }
        var record = run
        record.state = .expired
        record.finished = now
        record.summary = summary
        record.ownerPID = nil; record.ownerStart = nil
        return record
    }
}
