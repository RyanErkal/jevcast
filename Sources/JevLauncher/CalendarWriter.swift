import EventKit
import LauncherCore
import SwiftUI

/// A calendar an event can be saved to.
struct WritableCalendar: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String
    let color: Color
}

/// The open editor: a new event, or a change to the event with `eventID`.
struct CalendarEditing: Equatable {
    var draft: CalendarEventDraft
    /// Nil for a new event.
    var eventID: String?
    /// The start of the occurrence being changed, so one day of a repeating event can be found.
    var occurrence: Date?
    var recurring = false
    /// For a repeating event: this event only, or this and every later one.
    var future = false
    var isNew: Bool { eventID == nil }
}

/// Changes to events on this Mac's calendars. Tests use a fake; the app uses EventKit.
@MainActor
protocol CalendarWriting {
    func calendars() -> [WritableCalendar]
    var defaultCalendarID: String? { get }
    /// True when the Mac allows Jevcast to change events. Asks once when the user has not answered.
    func allowed() async -> Bool
    func save(_ draft: CalendarEventDraft, eventID: String?, occurrence: Date?, future: Bool) throws
    func delete(eventID: String, occurrence: Date?, future: Bool) throws
}

enum CalendarWriteError: LocalizedError {
    case noAccess, missing, noCalendar, readOnly
    var errorDescription: String? {
        switch self {
        case .noAccess: return "Allow Calendar access in System Settings › Privacy & Security › Calendars."
        case .missing: return "This event changed or was removed. Refresh and try again."
        case .noCalendar: return "No calendar on this Mac accepts new events. Add an account in System Settings › Internet Accounts."
        case .readOnly: return "This calendar does not allow changes."
        }
    }
}

/// Writes through EventKit, so the change reaches the account's server without Calendar open.
/// Every change is one the user made in the editor or confirmed in a dialog.
@MainActor
struct EventKitCalendarWriter: CalendarWriting {
    private var store: EKEventStore { Permissions.events }

    func calendars() -> [WritableCalendar] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map { WritableCalendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: CalendarPage.color(of: $0)) }
    }

    var defaultCalendarID: String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        if let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications { return calendar.calendarIdentifier }
        return calendars().first?.id
    }

    func allowed() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined { await Permissions.request(.calendars) }
        return EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func save(_ draft: CalendarEventDraft, eventID: String?, occurrence: Date?, future: Bool) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarWriteError.noAccess }
        let event: EKEvent
        if let eventID {
            guard let found = find(eventID, occurrence: occurrence) else { throw CalendarWriteError.missing }
            guard found.calendar?.allowsContentModifications == true else { throw CalendarWriteError.readOnly }
            event = found
        } else { event = EKEvent(eventStore: store) }
        if let id = draft.calendarID, let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications {
            if event.calendar?.calendarIdentifier != id { event.calendar = calendar }
        } else if event.calendar == nil {
            guard let fallback = defaultCalendarID.flatMap(store.calendar(withIdentifier:)) else { throw CalendarWriteError.noCalendar }
            event.calendar = fallback
        }
        let times = draft.storedTimes()
        event.title = draft.trimmedTitle
        event.isAllDay = draft.allDay
        event.startDate = times.start
        // EventKit's all-day end is the last day itself, not the day after.
        event.endDate = draft.allDay ? times.end.addingTimeInterval(-1) : times.end
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        try store.save(event, span: future ? .futureEvents : .thisEvent, commit: true)
    }

    func delete(eventID: String, occurrence: Date?, future: Bool) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarWriteError.noAccess }
        guard let event = find(eventID, occurrence: occurrence) else { throw CalendarWriteError.missing }
        guard event.calendar?.allowsContentModifications == true else { throw CalendarWriteError.readOnly }
        try store.remove(event, span: future ? .futureEvents : .thisEvent, commit: true)
    }

    /// The event, or for a repeating event the one occurrence that starts at `occurrence`.
    private func find(_ id: String, occurrence: Date?) -> EKEvent? {
        if let occurrence {
            let predicate = store.predicateForEvents(withStart: occurrence.addingTimeInterval(-1), end: occurrence.addingTimeInterval(86_400), calendars: nil)
            if let match = store.events(matching: predicate).first(where: { $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince(occurrence)) < 1 }) {
                return match
            }
        }
        guard let event = store.event(withIdentifier: id) else { return nil }
        // Without the occurrence, only an event that does not repeat is safe to change.
        return occurrence == nil || !event.hasRecurrenceRules ? event : nil
    }
}
