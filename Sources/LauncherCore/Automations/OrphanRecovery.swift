import Darwin
import Foundation

/// Kernel facts about a process, read without signalling it.
public enum ProcessInfoReader {
    /// The kernel start time of `pid`, from `PROC_PIDTBSDINFO`. Nil when there is no such process.
    public static func startTime(_ pid: pid_t) -> Date? {
        bsdInfo(pid).map { Date(timeIntervalSince1970: Double($0.pbi_start_tvsec) + Double($0.pbi_start_tvusec) / 1e6) }
    }

    /// The process group of `pid`. Nil when there is no such process.
    public static func groupID(_ pid: pid_t) -> pid_t? { bsdInfo(pid).map { pid_t($0.pbi_pgid) } }

    /// True while any process is in the group. EPERM means it exists but belongs to someone else.
    public static func groupExists(_ pgid: pid_t) -> Bool {
        guard pgid > 1 else { return false }
        return kill(-pgid, 0) == 0 || errno == EPERM
    }

    static func sameStart(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}

/// After a runner crash, stops a run's child group only when it is provably the same group:
/// the group's leader still exists, still leads that group, and started at the recorded time.
/// A PID or group ID alone is never enough, because the system reuses them.
public enum OrphanRecovery {
    public enum Outcome: Equatable, Sendable {
        /// No child was recorded, or its group is gone.
        case noChild
        /// A group with that ID exists but its leader is not the recorded child. It was left alone.
        case notOurs
        case stopped
        /// SIGKILL was sent, but something in the group was still there after it.
        case stillRunning
    }

    /// True when `run`'s recorded owner process is alive with a start time close to `ownerStart`.
    /// `ownerStart` is the runner's own clock at launch, so allow a few seconds.
    public static func ownerIsAlive(_ run: RunRecord, currentPID: pid_t = getpid()) -> Bool {
        guard let pid = run.ownerPID, let start = run.ownerStart, pid > 0, pid != currentPID,
              let kernelStart = ProcessInfoReader.startTime(pid) else { return false }
        return abs(start.timeIntervalSince(kernelStart)) < 30
    }

    public static func stopChild(of run: RunRecord, grace: TimeInterval = 10) -> Outcome {
        guard let pgid = run.childPGID, let expected = run.childStart, pgid > 1 else { return .noChild }
        guard ProcessInfoReader.groupExists(pgid) else { return .noChild }
        guard let start = ProcessInfoReader.startTime(pgid), ProcessInfoReader.groupID(pgid) == pgid,
              ProcessInfoReader.sameStart(start, expected) else { return .notOurs }
        kill(-pgid, SIGTERM)
        let end = Date().addingTimeInterval(grace)
        while Date() < end {
            if !ProcessInfoReader.groupExists(pgid) { return .stopped }
            usleep(50_000)
        }
        // Recheck the leader before the hard stop, in case the group ended and its ID was reused.
        if let now = ProcessInfoReader.startTime(pgid), ProcessInfoReader.groupID(pgid) == pgid, !ProcessInfoReader.sameStart(now, expected) {
            return .stopped
        }
        kill(-pgid, SIGKILL)
        for _ in 0..<40 {
            if !ProcessInfoReader.groupExists(pgid) { return .stopped }
            usleep(50_000)
        }
        return .stillRunning
    }

    /// Stops the child of an orphaned run and returns the record marked interrupted, for the runner to save.
    public static func interrupt(_ run: RunRecord, grace: TimeInterval = 10) -> RunRecord {
        var run = run
        let outcome = stopChild(of: run, grace: grace)
        let what: String
        switch outcome {
        case .noChild: what = "The runner stopped during this run. It was not repeated."
        case .stopped: what = "The runner stopped during this run. Its program was still running and was stopped. It was not repeated."
        case .notOurs: what = "The runner stopped during this run. Its program had already ended. It was not repeated."
        case .stillRunning: what = "The runner stopped during this run. Its program could not be stopped; check Activity Monitor. It was not repeated."
        }
        run.state = .interrupted
        run.error = what
        run.finished = Date()
        run.ownerPID = nil; run.ownerStart = nil
        run.childPGID = nil; run.childStart = nil
        return run
    }
}
