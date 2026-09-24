import AppKit
import EventKit
import LauncherCore

/// "remind me to call mum at 5pm" and "add event lunch with Sam friday 1pm".
extension LauncherModel {
    func createRow(_ create: CreateQuery) -> LauncherResult {
        let when = create.date.map { Self.createWhen($0, hasTime: create.hasTime, kind: create.kind) }
        switch create.kind {
        case .reminder:
            let verb = Verb(title: "Add Reminder", after: .close) { try await Self.addReminder(create); return nil }
            return LauncherResult(id: "create:reminder", title: "Remind me: " + create.title, detail: when ?? "No date · Reminders",
                                  symbol: "checklist", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 1850)
        case .event:
            let verb = Verb(title: "Add Event", after: .close) { try await Self.addEvent(create); return nil }
            return LauncherResult(id: "create:event", title: "Add event: " + create.title, detail: when ?? "",
                                  symbol: "calendar.badge.plus", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 1850)
        }
    }

    /// "Fri 26 Sep 13:00–14:00", or "Tomorrow" for a reminder with a day only.
    static func createWhen(_ date: Date, hasTime: Bool, kind: CreateQuery.Kind) -> String {
        let day = CalendarSource.dayName(date)
        let start = createStart(date, hasTime: hasTime, kind: kind)
        guard hasTime || kind == .event else { return day }
        let time = start.formatted(date: .omitted, time: .shortened)
        return kind == .event ? "\(day) \(time)–\(start.addingTimeInterval(3600).formatted(date: .omitted, time: .shortened))" : "\(day) \(time)"
    }

    /// An event on a day with no time starts at 09:00, or at the next full hour when 09:00 has passed.
    static func createStart(_ date: Date, hasTime: Bool, kind: CreateQuery.Kind, now: Date = Date()) -> Date {
        guard !hasTime, kind == .event else { return date }
        let cal = Calendar.current
        let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        guard nine < now, let hour = cal.dateInterval(of: .hour, for: now)?.end else { return nine }
        return hour
    }

    static func addReminder(_ create: CreateQuery, url: URL? = nil) async throws {
        let store = Permissions.events
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined { await Permissions.request(.reminders) }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw LauncherError("Reminders access is off. Turn on Jevcast in Privacy & Security › Reminders.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = create.title
        reminder.url = url
        guard let list = store.defaultCalendarForNewReminders() else { throw LauncherError("Reminders has no default list.") }
        reminder.calendar = list
        if let date = create.date {
            let fields: Set<Calendar.Component> = create.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: date)
            if create.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        try store.save(reminder, commit: true)
    }

    static func addEvent(_ create: CreateQuery) async throws {
        let store = Permissions.events
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined { await Permissions.request(.calendars) }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw LauncherError("Calendar access is off. Turn on Jevcast in Privacy & Security › Calendars.")
        }
        guard let date = create.date, let calendar = store.defaultCalendarForNewEvents else { throw LauncherError("Calendar has no default calendar.") }
        let event = EKEvent(eventStore: store)
        event.title = create.title
        event.calendar = calendar
        event.startDate = createStart(date, hasTime: create.hasTime, kind: .event)
        event.endDate = event.startDate.addingTimeInterval(3600)
        try store.save(event, span: .thisEvent, commit: true)
    }
}
