import Darwin
import Foundation

/// A displayed selection is valid only for the same kernel identities and the same process family.
public struct CleanupStopPlan: Sendable {
    public let finding: CleanupFinding
    public let identities: [CleanupIdentity]

    public init(finding: CleanupFinding, identities: [CleanupIdentity]) {
        self.finding = finding; self.identities = identities
    }

    public func validate(_ input: CleanupRules.Input, afterTermination: Bool = false) -> [CleanupIdentity]? {
        guard finding.canStop, !identities.isEmpty, Set(identities.map(\.pid)) == Set(finding.pids),
              identities.allSatisfy({ $0.uid == input.uid }) else { return nil }
        let remaining = identities.compactMap { expected -> CleanupProcess? in
            input.processes.first { $0.pid == expected.pid }
        }
        for process in remaining {
            guard let actual = process.identity, let expected = identities.first(where: { $0.pid == process.pid }),
                  expected.sameProcess(as: actual), actual.ppid == expected.ppid || (afterTermination && actual.ppid == 1) else { return nil }
        }
        if remaining.isEmpty { return [] }
        if !afterTermination {
            guard let fresh = CleanupRules.find(input).first(where: { $0.key == finding.key }), fresh.canStop,
                  fresh.group == finding.group, Set(fresh.pids) == Set(remaining.map(\.pid)) else { return nil }
        } else {
            // An app may have restarted a worker or added work after TERM. Never chase it.
            let parents = Dictionary(input.processes.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
            let original = Set(identities.map(\.pid))
            let hosts = input.protectedRoots.union(Set(input.processes.filter(ComputerUseCleanup.isAgentHost).map(\.pid)).subtracting(original))
            for process in remaining {
                guard !input.launchdPIDs.contains(process.pid), !CleanupRules.isSystem(process),
                      !CleanupRules.descends(process.pid, from: hosts, parents: parents) else { return nil }
                let family = input.processes.filter { CleanupRules.descends($0.pid, from: [process.pid], parents: parents) }
                guard family.allSatisfy({ original.contains($0.pid) && $0.uid == input.uid }) else { return nil }
                if finding.group == .computerUse {
                    guard process.cpu < 1, input.listening[process.pid] == nil else { return nil }
                }
            }
        }
        return remaining.compactMap(\.identity)
    }

    /// The identity is checked immediately before each individual signal. Never signal a group.
    public static func signal(_ expected: CleanupIdentity, force: Bool = false,
                              read: (Int32) -> CleanupIdentity? = CleanupIdentity.read,
                              send: (Int32, Int32) -> Int32 = { kill($0, $1) }) -> Bool {
        guard expected.pid > 1, expected.uid == getuid(), let current = read(expected.pid),
              expected.sameProcess(as: current), expected.ppid == current.ppid else { return false }
        return send(expected.pid, force ? SIGKILL : SIGTERM) == 0
    }
}
