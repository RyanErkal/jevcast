import Darwin
import Foundation

/// A named claim held for a whole staged run, in `Automations/claims/<name>.json`. Two runs never hold
/// the same claim. A claim left by a crashed runner is taken over only when its owner is gone and no
/// child group of its run may still be running.
public struct StagedClaims {
    public struct Owner: Codable, Equatable, Sendable {
        public var automationID: String
        public var runID: String
        public var ownerPID: Int32
        public var ownerStart: Date
        public var acquired: Date
    }

    public enum Result: Equatable, Sendable {
        case acquired
        /// Another live run, or an unconfirmed child group, holds it.
        case held(String)
        case failed(String)
    }

    public static let folderName = "claims"
    public let store: AutomationStore

    public init(store: AutomationStore) { self.store = store }

    var folder: URL { store.root.appendingPathComponent(Self.folderName, isDirectory: true) }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name + ".json") }

    public func acquire(_ name: String, run: RunRecord, pid: Int32, start: Date, now: Date = Date()) -> Result {
        guard AutomationID.isValid(name) else { return .failed("The claim name is not valid.") }
        do {
            try store.ensureRoot()
            try SecureFile.ensureDirectory(folder)
        } catch { return .failed("The claim folder could not be created: \(error)") }
        let owner = Owner(automationID: run.automationID, runID: run.id, ownerPID: pid, ownerStart: start, acquired: now)
        for _ in 0..<2 {
            if create(name, owner) { return .acquired }
            guard let current = read(name) else {
                // A claim file that cannot be read is never removed automatically.
                return .held("The claim \(name) exists but cannot be read. Check \(file(name).path).")
            }
            if current.runID == run.id, current.automationID == run.automationID { return .acquired }
            if let why = blocker(current, pid: pid) { return .held(why) }
            // The owner is gone and nothing of its run still runs: take the claim over.
            unlink(file(name).path)
        }
        return .held("The claim \(name) is in use.")
    }

    public func release(_ name: String, run: RunRecord) {
        guard let current = read(name), current.runID == run.id, current.automationID == run.automationID else { return }
        unlink(file(name).path)
    }

    public func read(_ name: String) -> Owner? {
        guard let data = try? SecureFile.read(file(name), maxBytes: 64 * 1024) else { return nil }
        return try? AutomationJSON.decoder().decode(Owner.self, from: data)
    }

    /// Why `owner` still holds its claim, or nil when it can be taken over.
    func blocker(_ owner: Owner, pid: Int32) -> String? {
        guard let run = store.run(automationID: owner.automationID, runID: owner.runID) else {
            // The owning run's record is gone, so its programs cannot be checked. The claim stays.
            return "The claim's run \(owner.runID) cannot be read, so its programs cannot be checked. Check \(folder.path)."
        }
        if StagedRecovery.hasLeftovers(store: store, run: run) {
            return "A program from an earlier run of \(owner.automationID) could not be confirmed stopped. Check Activity Monitor."
        }
        guard run.state.isActive else { return nil }
        let ownerAlive = owner.ownerPID == pid
            || ProcessInfoReader.startTime(owner.ownerPID).map { abs($0.timeIntervalSince(owner.ownerStart)) < 30 } == true
        if ownerAlive { return "Another run holds the claim (\(owner.automationID))." }
        if run.childPGID != nil, OrphanRecovery.groupMayRun(pgid: run.childPGID, start: run.childStart) {
            return "A program from an earlier run of \(owner.automationID) may still be running."
        }
        return nil
    }

    private func create(_ name: String, _ owner: Owner) -> Bool {
        guard let data = try? AutomationJSON.encoder().encode(owner) else { return false }
        let fd = open(file(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { unlink(file(name).path); return false }
        fsync(fd)
        return true
    }
}

/// Repeated failures alert once. A failure whose text matches the previous finished run's failure,
/// with digits ignored, is marked `repeatFailure` and does not alert again until the error changes
/// or a run succeeds.
public enum FailureDedupe {
    public static func key(_ run: RunRecord) -> String {
        let text = (run.error ?? run.summary).lowercased()
        return String(text.map { $0.isNumber ? "#" : $0 }.prefix(400))
    }

    /// `previous` is the newest finished run before `run`, if any.
    public static func isRepeat(_ run: RunRecord, previous: RunRecord?) -> Bool {
        guard [.failed, .interrupted].contains(run.state), let previous, [.failed, .interrupted].contains(previous.state) else { return false }
        return key(run) == key(previous)
    }
}

/// Programs a staged run may have left. The fetch tool runs its command in a group of its own, apart from
/// the CLI's group in `childPGID`, and records it in `item<n>-fetch-child.json`. Every recorded group is
/// checked, also after a finished result, because a timeout or cancel can leave members behind. A group
/// that may still run blocks work and is never signalled unless it is provably ours.
public enum StagedRecovery {
    /// Every fetch group the run recorded.
    public static func fetchChildren(store: AutomationStore, run: RunRecord) -> [FetchToolChild] {
        store.runFileNames(automationID: run.automationID, runID: run.id).filter { $0.hasSuffix("-fetch-child.json") }.map { name in
            guard let data = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: name) else {
                // A child file that cannot be read still says a group was started.
                return FetchToolChild(pgid: 0, start: nil)
            }
            return (try? AutomationJSON.decoder().decode(FetchToolChild.self, from: data)) ?? FetchToolChild(pgid: 0, start: nil)
        }
    }

    /// True while anything this run started may still run: its recorded unconfirmed group, or a fetch group.
    /// Active runs are their owner's business; every other state is checked, cancelled and succeeded too.
    public static func mayRun(store: AutomationStore, run: RunRecord) -> Bool {
        if run.orphanPGID != nil, OrphanRecovery.groupMayRun(pgid: run.orphanPGID, start: run.orphanStart) { return true }
        guard !run.state.isActive else { return false }
        return hasLeftovers(store: store, run: run)
    }

    /// The same check whatever the run's state, for the engine at the end of its own run.
    public static func hasLeftovers(store: AutomationStore, run: RunRecord) -> Bool {
        if run.orphanPGID != nil, OrphanRecovery.groupMayRun(pgid: run.orphanPGID, start: run.orphanStart) { return true }
        return fetchChildren(store: store, run: run).contains { child in
            // An unreadable record (pgid 0) cannot be checked, so it blocks.
            child.pgid <= 1 || OrphanRecovery.groupMayRun(pgid: child.pgid, start: child.start)
        }
    }

    /// Stops the run's fetch groups that are provably ours. Returns the first group that may still run, or nil.
    public static func stopFetchChildren(store: AutomationStore, run: RunRecord, grace: TimeInterval) -> FetchToolChild? {
        for child in fetchChildren(store: store, run: run) {
            guard child.pgid > 1 else { return child }
            var probe = run
            probe.childPGID = child.pgid; probe.childStart = child.start
            switch OrphanRecovery.stopChild(of: probe, grace: grace) {
            case .noChild, .notOurs, .stopped: continue
            case .stillRunning, .unconfirmed: return child
            }
        }
        return nil
    }
}
