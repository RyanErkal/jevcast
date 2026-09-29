import Foundation
import LauncherCore
import UserNotifications

/// Local notifications for timers and command output. Nothing is sent off the Mac.
@MainActor
enum Notifier {
    /// Asks once. Returns false when the user has turned notifications off for Jevcast.
    static func authorize() async -> Bool {
        // Outside an app bundle, such as in tests or a diagnostic run, macOS has no notifications to give.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    static func post(id: String = UUID().uuidString, title: String, body: String, after seconds: TimeInterval? = nil,
                     userInfo: [String: Any] = [:]) async -> Bool {
        guard await authorize() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: max($0, 1), repeats: false) }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return true
        } catch { return false }
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

/// Timers started from the launcher. macOS delivers the notification even if Jevcast quits.
/// Each notification carries its label and end time, so the list comes back after a relaunch.
@MainActor
final class TimerCenter: ObservableObject {
    struct Active: Identifiable, Equatable {
        let id: String
        let label: String
        let fires: Date
        var title: String { label.isEmpty ? "Timer" : label }
    }
    static let shared = TimerCenter()
    static let idPrefix = "timer."
    private static let firesKey = "timerFires", labelKey = "timerLabel"
    @Published private(set) var active: [Active] = []

    /// Starts a timer. Returns a failure message, or nil on success.
    func start(_ timer: TimerQuery, now: Date = Date()) async -> String? {
        let id = Self.idPrefix + UUID().uuidString
        let title = timer.label.isEmpty ? "Timer done" : timer.label
        let fires = now.addingTimeInterval(TimeInterval(timer.seconds))
        guard await Notifier.post(id: id, title: title, body: TimerQuery.describe(timer.seconds) + " timer from Jevcast", after: TimeInterval(timer.seconds),
                                  userInfo: [Self.firesKey: fires.timeIntervalSince1970, Self.labelKey: timer.label]) else {
            return "Allow notifications for Jevcast in System Settings › Notifications to use timers."
        }
        add(Active(id: id, label: timer.label, fires: fires), now: now)
        return nil
    }

    /// Lists the timers macOS still holds, after a relaunch. A timer that ended while Jevcast was
    /// closed is no longer pending, so it does not show. Timers from older versions carry no end time and stay hidden.
    func restore(now: Date = Date()) async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        for request in pending {
            guard let timer = Self.timer(id: request.identifier, userInfo: request.content.userInfo, now: now) else { continue }
            add(timer, now: now)
        }
    }

    /// The timer a pending notification stands for, or nil when it is not a running timer.
    static func timer(id: String, userInfo: [AnyHashable: Any], now: Date) -> Active? {
        guard id.hasPrefix(idPrefix), let seconds = userInfo[firesKey] as? Double else { return nil }
        let fires = Date(timeIntervalSince1970: seconds)
        guard fires > now else { return nil }
        return Active(id: id, label: userInfo[labelKey] as? String ?? "", fires: fires)
    }

    private func add(_ entry: Active, now: Date) {
        guard !active.contains(where: { $0.id == entry.id }) else { return }
        active.append(entry)
        active.sort { $0.fires < $1.fires }
        let id = entry.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(entry.fires.timeIntervalSince(now), 0) * 1_000_000_000))
            self?.active.removeAll { $0.id == id }
        }
    }

    func cancel(_ id: String) {
        Notifier.cancel(id: id)
        active.removeAll { $0.id == id }
    }
}
