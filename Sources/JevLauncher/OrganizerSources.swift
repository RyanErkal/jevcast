import AppKit
import Contacts
import EventKit
import LauncherCore

/// Upcoming events. "calendar" lists today and tomorrow; "calendar week" the next seven days;
/// "calendar tomorrow" one day; other words search titles over the next 30 days.
@MainActor
final class CalendarSource: ThingSource {
    let section = "Calendar"
    private var store: EKEventStore { Permissions.events }

    func load(_ filter: String) async throws -> [LauncherResult] {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined: throw SourceProblem(text: "Allow Calendar access to list your events.", access: .calendars)
        default: throw SourceProblem(text: "Calendar access is off. Turn on Jevcast in Privacy & Security › Calendars.", access: .calendars)
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let words = filter.lowercased()
        var start = Date(), end = cal.date(byAdding: .day, value: 2, to: today)!, text = ""
        switch words {
        case "": break
        case "today": end = cal.date(byAdding: .day, value: 1, to: today)!
        case "tomorrow": start = cal.date(byAdding: .day, value: 1, to: today)!; end = cal.date(byAdding: .day, value: 2, to: today)!
        case "week", "this week", "next 7 days": end = cal.date(byAdding: .day, value: 7, to: today)!
        default: end = cal.date(byAdding: .day, value: 30, to: today)!; text = filter
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // Cancelled events and invitations the user declined are not on their day.
        let events = store.events(matching: predicate).filter { event in
            event.status != .canceled && !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
        }.sorted { $0.startDate < $1.startDate }
        let matching = text.isEmpty ? events : events.filter { SearchRanking.score(query: text, title: $0.title ?? "") != nil }
        return matching.prefix(60).enumerated().map { index, event in row(event, score: 3000 - Double(index)) }
    }

    private func row(_ event: EKEvent, score: Double) -> LauncherResult {
        var parts = [Self.when(event)]
        if let name = event.calendar?.title { parts.append(name) }
        if let location = event.location, !location.isEmpty { parts.append(location) }
        let link = MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])
        if link != nil { parts.append("video call") }
        let eventID = event.eventIdentifier
        let id = eventID ?? UUID().uuidString
        var verbs: [Verb] = []
        if let link { verbs.append(Verb(title: "Join Call") { NSWorkspace.shared.open(link); return nil }) }
        verbs.append(Verb(title: "Open in Calendar") {
            // ical://ekevent is not documented. Without an identifier, open Calendar itself.
            let url = eventID.flatMap { URL(string: "ical://ekevent/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)?method=show&options=more") }
            if url.map({ NSWorkspace.shared.open($0) }) != true { Self.openApp("com.apple.iCal") }
            return nil
        })
        // Only the organizer's own events move. Moving an invitation makes a local change the server may undo.
        let ownEvent = event.organizer == nil || event.organizer?.isCurrentUser == true
        if !event.isAllDay && ownEvent && event.calendar?.allowsContentModifications == true {
            for (title, minutes) in [("Move 15 Minutes Later", 15), ("Move 1 Hour Later", 60)] {
                verbs.append(Verb(title: title, after: .stay) { [store] in
                    // The event may have changed in Calendar since the list loaded.
                    guard event.refresh() else { throw LauncherError("This event changed or was deleted. The list is up to date now.") }
                    event.startDate = event.startDate.addingTimeInterval(Double(minutes) * 60)
                    event.endDate = event.endDate.addingTimeInterval(Double(minutes) * 60)
                    try store.save(event, span: .thisEvent, commit: true)
                    return "Moved \(event.title ?? "the event") to \(event.startDate.formatted(date: .omitted, time: .shortened))."
                })
            }
        }
        verbs.append(Verb(title: "Copy Details", after: .stay) {
            var text = (event.title ?? "") + "\n" + Self.when(event)
            if let location = event.location, !location.isEmpty { text += "\n" + location }
            if let link { text += "\n" + link.absoluteString }
            copyText(text); return "Details copied."
        })
        return LauncherResult(id: "event:" + id + ":\(event.startDate.timeIntervalSince1970)", title: event.title ?? "Untitled event",
                              detail: parts.joined(separator: " · "), symbol: link != nil ? "video" : "calendar",
                              action: .thing(Thing(verbs: verbs)), score: score)
    }

    /// "Today 14:00–15:00", "Tomorrow, all day", "Fri 26 Sep 09:00–09:30".
    static func when(_ event: EKEvent) -> String {
        let day = dayName(event.startDate)
        if event.isAllDay { return day + ", all day" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        let now = Date()
        if event.startDate <= now && event.endDate > now { return "Now until \(end)" }
        return "\(day) \(start)–\(end)"
    }

    static func dayName(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Open reminders, overdue and soonest first. Words filter titles.
@MainActor
final class RemindersSource: ThingSource {
    let section = "Reminders"
    private var store: EKEventStore { Permissions.events }

    func load(_ filter: String) async throws -> [LauncherResult] {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: break
        case .notDetermined: throw SourceProblem(text: "Allow Reminders access to list your reminders.", access: .reminders)
        default: throw SourceProblem(text: "Reminders access is off. Turn on Jevcast in Privacy & Security › Reminders.", access: .reminders)
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                nonisolated(unsafe) let found = found ?? []
                continuation.resume(returning: found)
            }
        }
        let cal = Calendar.current
        let sorted = reminders.sorted { lhs, rhs in
            let l = lhs.dueDateComponents.flatMap { cal.date(from: $0) } ?? .distantFuture
            let r = rhs.dueDateComponents.flatMap { cal.date(from: $0) } ?? .distantFuture
            return l != r ? l < r : (lhs.title ?? "") < (rhs.title ?? "")
        }
        let matching = filter.isEmpty ? sorted : sorted.filter { SearchRanking.score(query: filter, title: $0.title ?? "") != nil }
        return matching.prefix(80).enumerated().map { index, reminder in row(reminder, score: 3000 - Double(index)) }
    }

    private func row(_ reminder: EKReminder, score: Double) -> LauncherResult {
        var parts: [String] = []
        let cal = Calendar.current
        var overdue = false
        if let components = reminder.dueDateComponents, let due = cal.date(from: components) {
            let hasTime = components.hour != nil
            overdue = hasTime ? due < Date() : due < cal.startOfDay(for: Date())
            let day = CalendarSource.dayName(due)
            parts.append((overdue ? "Overdue · " : "") + (hasTime ? day + " " + due.formatted(date: .omitted, time: .shortened) : day))
        }
        if let list = reminder.calendar?.title { parts.append(list) }
        if let notes = reminder.notes?.split(whereSeparator: \.isNewline).first { parts.append(String(notes.prefix(60))) }
        let id = reminder.calendarItemIdentifier
        let verbs = [
            Verb(title: "Complete", after: .stay) { [store] in
                guard reminder.refresh() else { throw LauncherError("This reminder changed or was deleted.") }
                reminder.isCompleted = true
                try store.save(reminder, commit: true)
                return "Completed \(reminder.title ?? "the reminder")."
            },
            Verb(title: "Open in Reminders") {
                let url = URL(string: "x-apple-reminderkit://REMCDReminder/" + id)
                if url.map({ NSWorkspace.shared.open($0) }) != true { CalendarSource.openApp("com.apple.reminders") }
                return nil
            },
            Verb(title: "Move to Tomorrow", after: .stay) { [store] in
                let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
                var components = cal.dateComponents([.year, .month, .day], from: tomorrow)
                if let old = reminder.dueDateComponents, let hour = old.hour { components.hour = hour; components.minute = old.minute ?? 0 }
                guard reminder.refresh() else { throw LauncherError("This reminder changed or was deleted.") }
                let oldDue = reminder.dueDateComponents.flatMap { cal.date(from: $0) }
                reminder.dueDateComponents = components
                // Time alarms move with the reminder. Location and relative alarms stay as they are.
                if let oldDue, let newDue = cal.date(from: components) {
                    let shift = newDue.timeIntervalSince(oldDue)
                    for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil {
                        alarm.absoluteDate = alarm.absoluteDate?.addingTimeInterval(shift)
                    }
                } else if components.hour != nil, let date = cal.date(from: components) { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
                try store.save(reminder, commit: true)
                return "Moved \(reminder.title ?? "the reminder") to tomorrow."
            },
            Verb(title: "Copy Title", after: .stay) { copyText(reminder.title ?? ""); return "Title copied." }
        ]
        return LauncherResult(id: "reminder:" + id, title: reminder.title ?? "Untitled reminder", detail: parts.joined(separator: " · "),
                              symbol: overdue ? "exclamationmark.circle" : "circle", action: .thing(Thing(verbs: verbs)), score: score)
    }
}

/// People from Contacts, by name, then by email or phone number. Return writes an email when there is an address.
@MainActor
final class ContactsSource: ThingSource {
    let section = "Contacts"

    struct Person: Sendable {
        let id: String, name: String, organization: String
        let emails: [String], phones: [String]
    }

    func load(_ filter: String) async throws -> [LauncherResult] {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: break
        case .notDetermined: throw SourceProblem(text: "Allow Contacts access to find people.", access: .contacts)
        default: throw SourceProblem(text: "Contacts access is off. Turn on Jevcast in Privacy & Security › Contacts.", access: .contacts)
        }
        guard !filter.isEmpty else { throw SourceProblem(text: "Type a name after “contact”, such as “contact sam”.") }
        let people = await Task.detached(priority: .userInitiated) { Self.search(filter) }.value
        return people.prefix(20).enumerated().map { index, person in row(person, score: 3000 - Double(index)) }
    }

    nonisolated static func search(_ text: String) -> [Person] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactOrganizationNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
                                       CNContactPhoneNumbersKey as CNKeyDescriptor]
        var found: [CNContact] = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: text), keysToFetch: keys)) ?? []
        if found.isEmpty, text.contains("@") {
            found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: text), keysToFetch: keys)) ?? []
        }
        if found.isEmpty, text.filter(\.isNumber).count >= 4 {
            let number = CNPhoneNumber(stringValue: text)
            found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matching: number), keysToFetch: keys)) ?? []
        }
        return found.map { contact in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            return Person(id: contact.identifier, name: name.isEmpty ? "No name" : name, organization: contact.organizationName,
                          emails: contact.emailAddresses.map { String($0.value) },
                          phones: contact.phoneNumbers.map { $0.value.stringValue })
        }
    }

    private func row(_ person: Person, score: Double) -> LauncherResult {
        var verbs: [Verb] = []
        for email in person.emails.prefix(3) {
            verbs.append(Verb(title: "Email " + email) {
                if let url = URL(string: "mailto:" + email) { NSWorkspace.shared.open(url) }
                return nil
            })
        }
        for phone in person.phones.prefix(3) {
            let digits = phone.filter { $0.isNumber || $0 == "+" }
            verbs.append(Verb(title: "Message " + phone) {
                if let url = URL(string: "sms:" + digits) { NSWorkspace.shared.open(url) }
                return nil
            })
            verbs.append(Verb(title: "Call " + phone) {
                if let url = URL(string: "tel:" + digits) { NSWorkspace.shared.open(url) }
                return nil
            })
        }
        verbs.append(Verb(title: "Open in Contacts") {
            if let url = URL(string: "addressbook://" + person.id) { NSWorkspace.shared.open(url) }
            return nil
        })
        for email in person.emails.prefix(3) { verbs.append(Verb(title: "Copy " + email, after: .stay) { copyText(email); return "Email copied." }) }
        for phone in person.phones.prefix(3) { verbs.append(Verb(title: "Copy " + phone, after: .stay) { copyText(phone); return "Number copied." }) }
        let detail = ([person.organization] + person.emails.prefix(1) + person.phones.prefix(1)).filter { !$0.isEmpty }.joined(separator: " · ")
        return LauncherResult(id: "contact:" + person.id, title: person.name, detail: detail, symbol: "person.crop.circle",
                              action: .thing(Thing(verbs: verbs)), score: score)
    }
}

@MainActor func copyText(_ text: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
}
