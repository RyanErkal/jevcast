import AppKit
import Darwin
import LauncherCore

/// Keeps one copy of Jevcast running. A second copy asks the first to show the launcher and exits.
@MainActor
enum InstanceGuard {
    /// Posted by a second copy. The running copy shows the launcher.
    static let showNotification = Notification.Name(AppIdentity.bundleID + ".showLauncher")
    /// Held open for the life of the process. The system drops the lock when the process ends.
    private static var lockDescriptor: Int32 = -1

    static var lockURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("instance.lock")
    }

    /// Returns the decision. For `.handOff` it has already signalled the other copy.
    static func check(arguments: [String] = CommandLine.arguments) -> SingleInstance.Decision {
        if SingleInstance.isDiagnostic(arguments) { return .diagnostic }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        let decision = SingleInstance.decide(arguments: arguments, otherProcesses: others.count, lockAcquired: acquireLock())
        // The runner opens the app for alerts; the running copy already shows them. That hand-off
        // neither shows the launcher nor brings the running copy to the front.
        if decision == .handOff, !arguments.contains("--automation-alerts") {
            DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
            others.first?.activate()
        }
        return decision
    }

    private static func acquireLock() -> Bool? {
        let url = lockURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        // Without a lock file, the process check still applies.
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(fd)
            return busy ? false : nil
        }
        lockDescriptor = fd
        return true
    }
}
