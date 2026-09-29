import AppKit
import LauncherCore

/// Starts Apple Mail hidden, one launch at a time. Callers that arrive meanwhile wait for it instead
/// of opening Mail again: a second open reaches a Mail that is still starting, and Mail answers it by
/// showing its window. A Mail that is quitting still counts as running, and a script sent to it then
/// starts Mail again the normal way, with its window. So a launch first waits until it has ended.
@MainActor
final class MailLaunch {
    enum State: Equatable { case stopped, running, quitting }

    private let state: () -> State
    private let waitForQuit: () async -> Void
    private let open: () async throws -> Void
    private var launch: Task<Void, Error>?

    init(state: @escaping () -> State, waitForQuit: @escaping () async -> Void, open: @escaping () async throws -> Void) {
        self.state = state; self.waitForQuit = waitForQuit; self.open = open
    }

    func ensureRunning() async throws {
        if let launch { return try await launch.value }
        if state() == .running { return }
        let task = Task { @MainActor in
            if self.state() == .quitting { await self.waitForQuit() }
            // A Mail that did not quit, such as one that asks about unsent mail, is still running.
            guard self.state() == .stopped else { return }
            try await self.open()
        }
        launch = task
        defer { launch = nil }
        try await task.value
    }
}

extension MailActions {
    @MainActor static let launcher = MailLaunch(state: { mailState() }, waitForQuit: { await waitForQuit() }, open: { try await openHidden() })

    /// The Mail that Jevcast asked to quit, until it has ended.
    @MainActor private static var quittingPID: pid_t?

    @MainActor static func mailState() -> MailLaunch.State {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        if apps.isEmpty { return .stopped }
        return apps.allSatisfy { $0.processIdentifier == quittingPID } ? .quitting : .running
    }

    /// Asks Mail to quit and waits until it has, up to 10 seconds. A launch meanwhile waits too.
    @MainActor static func quit(_ app: NSRunningApplication) async {
        quittingPID = app.processIdentifier
        app.terminate()
        await waitForQuit()
    }

    @MainActor private static func waitForQuit() async {
        var tries = 0
        while mailState() == .quitting, !Task.isCancelled, tries < 100 {
            tries += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // A Mail that did not quit in 10 seconds, such as one that asks about unsent mail, counts as running again.
        if tries == 100, mailState() == .quitting { quittingPID = nil }
    }

    /// Starts Mail hidden, without taking focus, and waits until it answers.
    @MainActor private static func openHidden() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw LauncherError("Apple Mail is not installed.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false; config.hides = true; config.addsToRecentItems = false
        quittingPID = nil
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        MailHider.keepHidden(app, for: 10)
        for _ in 0..<40 where !AppleScript.isRunning(bundleID) { try await Task.sleep(nanoseconds: 100_000_000) }
        // Mail answers scripts a moment after it launches.
        try await Task.sleep(nanoseconds: 800_000_000)
        // Mail can restore its last window while it starts. The Mail that Jevcast started stays out of sight.
        _ = app.hide()
    }
}

/// Keeps a Mail that Jevcast started out of sight for its first seconds. Mail can restore its last
/// window, or come to the front, a while after it starts; each time, it is hidden again. Mail that
/// you open yourself (`MailActions.openedByUser`) stops this at once.
@MainActor
final class MailHider {
    private static var current: MailHider?
    private var observers: [NSObjectProtocol] = []

    static func keepHidden(_ app: NSRunningApplication, for seconds: TimeInterval) {
        current?.end()
        let hider = MailHider()
        current = hider
        let pid = app.processIdentifier
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            hider.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak hider] note in
                guard let shown = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      shown.processIdentifier == pid else { return }
                MainActor.assumeIsolated {
                    if MailActions.openedByUser { hider?.end() } else { _ = shown.hide() }
                }
            })
        }
        Task { @MainActor [weak hider] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            hider?.end()
        }
    }

    private func end() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers = []
        if Self.current === self { Self.current = nil }
    }
}
