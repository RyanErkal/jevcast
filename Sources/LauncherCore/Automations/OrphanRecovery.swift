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
        /// The group exists but its leader is gone or unreadable, so it could not be proved ours. Not signalled.
        case unconfirmed
    }

    /// True when `run`'s recorded owner process is alive with a start time close to `ownerStart`.
    /// `ownerStart` is the runner's own clock at launch, so allow a few seconds.
    public static func ownerIsAlive(_ run: RunRecord, currentPID: pid_t = getpid()) -> Bool {
        guard let pid = run.ownerPID, let start = run.ownerStart, pid > 0, pid != currentPID,
              let kernelStart = ProcessInfoReader.startTime(pid) else { return false }
        return abs(start.timeIntervalSince(kernelStart)) < 30
    }

    /// What is known about a recorded child group now.
    public enum GroupState: Equatable, Sendable {
        /// No process is in the group, or the ID now leads a newer group (the system reuses a group ID only
        /// after the old group is empty). Safe to forget.
        case gone
        /// The group exists and its leader is the recorded process.
        case ours
        /// The group exists, but its leader has exited or cannot be read. Its members may be ours, so it
        /// blocks work and is never signalled.
        case unknown
    }

    public static func groupState(pgid: Int32?, start: Date?) -> GroupState {
        guard let pgid, pgid > 1 else { return .gone }
        guard ProcessInfoReader.groupExists(pgid) else { return .gone }
        guard let start, let leader = ProcessInfoReader.startTime(pgid), ProcessInfoReader.groupID(pgid) == pgid else { return .unknown }
        return ProcessInfoReader.sameStart(leader, start) ? .ours : .gone
    }

    /// True unless the group is provably gone: work waits for a group that is ours or unknown.
    public static func groupMayRun(pgid: Int32?, start: Date?) -> Bool { groupState(pgid: pgid, start: start) != .gone }

    /// A run's recorded unconfirmed group that has since ended, with its fields cleared. Nil while it may still run or when there is none.
    public static func resolvedOrphan(_ run: RunRecord) -> RunRecord? {
        guard run.orphanPGID != nil, !groupMayRun(pgid: run.orphanPGID, start: run.orphanStart) else { return nil }
        var record = run
        record.orphanPGID = nil; record.orphanStart = nil
        return record
    }

    public static func stopChild(of run: RunRecord, grace: TimeInterval = 10) -> Outcome {
        guard let pgid = run.childPGID, pgid > 1 else { return .noChild }
        // A group with no recorded start time cannot be proved ours: it is never signalled, and it blocks.
        guard let expected = run.childStart else { return ProcessInfoReader.groupExists(pgid) ? .unconfirmed : .noChild }
        switch groupState(pgid: pgid, start: expected) {
        case .gone: return ProcessInfoReader.groupExists(pgid) ? .notOurs : .noChild
        case .unknown: return .unconfirmed
        case .ours: break
        }
        kill(-pgid, SIGTERM)
        let end = Date().addingTimeInterval(grace)
        while Date() < end {
            if !ProcessInfoReader.groupExists(pgid) { return .stopped }
            usleep(50_000)
        }
        // Check again before the hard stop: the leader may have exited (unknown) or the ID may lead a new group (gone).
        switch groupState(pgid: pgid, start: expected) {
        case .gone: return .stopped
        case .unknown: return .unconfirmed
        case .ours: break
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
        case .stillRunning: what = "The runner stopped during this run. Its program could not be stopped; check Activity Monitor. This automation waits until that program ends."
        case .unconfirmed: what = "The runner stopped during this run. Part of its program may still be running and could not be checked, so it was left alone. This automation waits until it ends."
        }
        // An unconfirmed group keeps its identity, so later runs wait for it instead of working beside it.
        if outcome == .stillRunning || outcome == .unconfirmed { run.orphanPGID = run.childPGID; run.orphanStart = run.childStart }
        run.state = .interrupted
        run.error = what
        run.finished = Date()
        run.ownerPID = nil; run.ownerStart = nil
        run.childPGID = nil; run.childStart = nil
        return run
    }
}
