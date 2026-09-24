import AppKit
import Contacts
import EventKit

/// Asks for the permissions sources need. A first request shows the macOS prompt;
/// after a refusal, only System Settings can grant it, so that pane opens.
@MainActor
enum Permissions {
    static let events = EKEventStore()

    static func request(_ access: SourceAccess) async {
        switch access {
        case .calendars:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined { _ = try? await events.requestFullAccessToEvents() }
            else { open("Privacy_Calendars") }
        case .reminders:
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined { _ = try? await events.requestFullAccessToReminders() }
            else { open("Privacy_Reminders") }
        case .contacts:
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined { _ = try? await CNContactStore().requestAccess(for: .contacts) }
            else { open("Privacy_Contacts") }
        case .automation: open("Privacy_Automation")
        case .fullDiskAccess: open("Privacy_AllFiles")
        }
    }

    static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        NSWorkspace.shared.open(url)
    }
}
