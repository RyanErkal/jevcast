import Foundation
import LauncherCore
import UserNotifications

/// Local notifications for timers and command output. Nothing is sent off the Mac.
@MainActor
enum Notifier {
    /// Asks once. Returns false when the user has turned notifications off for Jevcast.
    static func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    static func post(id: String = UUID().uuidString, title: String, body: String, after seconds: TimeInterval? = nil) async -> Bool {
        guard await authorize() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
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
@MainActor
final class TimerCenter: ObservableObject {
    struct Active: Identifiable, Equatable {
        let id: String
        let label: String
        let fires: Date
        var title: String { label.isEmpty ? "Timer" : label }
    }
    static let shared = TimerCenter()
    @Published private(set) var active: [Active] = []

    /// Starts a timer. Returns a failure message, or nil on success.
    func start(_ timer: TimerQuery, now: Date = Date()) async -> String? {
        let id = "timer." + UUID().uuidString
        let title = timer.label.isEmpty ? "Timer done" : timer.label
        guard await Notifier.post(id: id, title: title, body: TimerQuery.describe(timer.seconds) + " timer from Jevcast", after: TimeInterval(timer.seconds)) else {
            return "Allow notifications for Jevcast in System Settings › Notifications to use timers."
        }
        let entry = Active(id: id, label: timer.label, fires: now.addingTimeInterval(TimeInterval(timer.seconds)))
        active.append(entry)
        active.sort { $0.fires < $1.fires }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timer.seconds) * 1_000_000_000)
            self?.active.removeAll { $0.id == id }
        }
        return nil
    }

    func cancel(_ id: String) {
        Notifier.cancel(id: id)
        active.removeAll { $0.id == id }
    }
}
