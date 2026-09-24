import AppKit

/// Update state for the menu and Settings. An automatic check runs at most once
/// a day and only while "Check for updates automatically" is on.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable { case idle, checking, current, available(AppRelease), failed(String) }
    @Published private(set) var state: State = .idle
    static let interval: TimeInterval = 24 * 60 * 60
    private let service: UpdateService
    private let preferences: Preferences
    private let currentVersion: String
    private var scheduler: NSBackgroundActivityScheduler?

    init(preferences: Preferences, service: UpdateService = UpdateService(), currentVersion: String = AppIdentity.version) {
        self.preferences = preferences; self.service = service; self.currentVersion = currentVersion
    }

    var available: AppRelease? { if case .available(let release) = state { return release }; return nil }

    /// Checks soon after launch when a day has passed, then lets the system pick an idle moment each day.
    func start() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self?.checkIfDue()
        }
        let scheduler = NSBackgroundActivityScheduler(identifier: AppIdentity.bundleID + ".update-check")
        scheduler.repeats = true
        scheduler.interval = Self.interval
        scheduler.tolerance = 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.checkIfDue()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    func checkIfDue(now: Date = Date()) async {
        guard preferences.checksForUpdates else { return }
        if let last = preferences.lastUpdateCheck, now.timeIntervalSince(last) < Self.interval { return }
        await check()
    }

    /// A second call while a check runs waits for that check instead of starting another.
    func check() async {
        if let running { await running.value; return }
        let task = Task { await performCheck() }
        running = task
        await task.value
        running = nil
    }
    private var running: Task<Void, Never>?
    private func performCheck() async {
        state = .checking
        do {
            let release = try await service.newerRelease(than: currentVersion)
            state = release.map(State.available) ?? .current
            preferences.lastUpdateCheck = Date()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The menu command: check now, then report the result in an alert.
    func checkAndReport() {
        Task {
            await check()
            NSApp.activate()
            let alert = NSAlert()
            switch state {
            case .available(let release):
                alert.messageText = "\(AppIdentity.name) \(release.version) is available"
                alert.informativeText = "You have version \(currentVersion). The download page opens in your browser."
                alert.addButton(withTitle: "Open Download Page")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { Frontmost.open(release.page) }
            case .current:
                alert.messageText = "\(AppIdentity.name) is up to date"
                alert.informativeText = "Version \(currentVersion) is the newest version."
                alert.runModal()
            case .failed(let message):
                alert.messageText = "Could not check for updates"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.runModal()
            case .idle, .checking:
                break
            }
        }
    }
}
