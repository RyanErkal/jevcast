import AppKit
import LauncherCore

extension Cleanup {
    static func processInput() async throws -> CleanupRules.Input {
        let apps = NSWorkspace.shared.runningApplications
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var protectedRoots = Set(apps.filter { app in
            app.activationPolicy == .regular || app.bundleIdentifier.map(protectedApps.contains) == true
                || app.processIdentifier == front || app.processIdentifier == getpid()
        }.map(\.processIdentifier))
        async let output = CommandRunner.capture(["/bin/ps"] + CleanupProcess.psArguments, timeout: 10)
        async let jobs = CommandRunner.capture(["/bin/launchctl", "list"], timeout: 10)
        // lsof returns 1 for no matches. A warning or any other failure leaves the scan unavailable.
        async let portOutput = CommandRunner.capture(["/usr/sbin/lsof"] + ListeningPorts.lsofArguments, timeout: 10,
                                                     acceptedExitCodes: [0, 1], requireEmptyStderr: true)
        let parsed = CleanupProcess.parse(try await output)
        guard !parsed.isEmpty else { throw CommandRunner.Failure(text: "The process list could not be read.") }
        let processes = await Task.detached {
            parsed.map { process in
                let identity = CleanupIdentity.read(process.pid)
                return CleanupProcess(pid: process.pid, ppid: identity?.ppid ?? process.ppid, uid: identity?.uid ?? process.uid,
                                      cpu: process.cpu, memoryMB: process.memoryMB,
                                      elapsed: identity.map { max(0, Date().timeIntervalSince1970 - Double($0.startedSeconds)) } ?? process.elapsed,
                                      path: identity?.path ?? process.path, identity: identity)
            }
        }.value
        // Unreadable facts never become permission to stop something.
        protectedRoots.formUnion(processes.filter { $0.identity?.arguments == nil }.map(\.pid))
        let launchdPIDs = Set(LaunchStatus.parse(try await jobs).values.compactMap(\.pid))
        var listening: [Int32: [Int]] = [:]
        for port in ListeningPorts.parse(try await portOutput) { listening[port.pid, default: []].append(port.port) }
        return .init(processes: processes, uid: getuid(), listening: listening, launchdPIDs: launchdPIDs,
                     protectedRoots: protectedRoots, ignoredKeys: [])
    }
}
