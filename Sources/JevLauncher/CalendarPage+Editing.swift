import AppKit
import EventKit
import LauncherCore

/// New events, changes, moves, and deletes. Each one goes to this Mac's calendars through the
/// writer, and only after the user saved the editor, dropped an event, or confirmed a delete.
extension CalendarPage {
    var writableCalendars: [WritableCalendar] { writer?.calendars() ?? [] }

    /// Opens the editor for a new event on `day` (today's anchor when nil), at `minute` of the day when given.
    func beginCreate(on day: Date? = nil, minute: Int? = nil) {
        guard let writer, editing == nil else { return }
        editProblem = nil
        let target = day ?? (Calendar.current.isDateInToday(anchor) || days.contains(where: Calendar.current.isDateInToday) ? Date() : anchor)
        var draft = CalendarEventDraft.new(on: target, minute: minute)
        Task { @MainActor [weak self] in
            guard await writer.allowed() else { self?.editProblem = CalendarWriteError.noAccess.localizedDescription; return }
            guard let self, self.editing == nil else { return }
            draft.calendarID = self.defaults?.string(forKey: "calendarLastWritten").flatMap { id in writer.calendars().first { $0.id == id }?.id }
                ?? writer.defaultCalendarID
            guard draft.calendarID != nil else { self.editProblem = CalendarWriteError.noCalendar.localizedDescription; return }
            self.clearSelection()
            self.editing = CalendarEditing(draft: draft)
        }
    }

    func beginEdit(_ event: Event) {
        guard writer != nil, event.editable, let id = event.localID else { return }
        editProblem = nil
        // An all-day event ends at the start of the next day; the editor shows its last day.
        let end = event.allDay ? max(event.start, event.end.addingTimeInterval(-1)) : event.end
        editing = CalendarEditing(draft: CalendarEventDraft(title: event.title, start: event.start, end: end, allDay: event.allDay,
                                                            calendarID: event.calendarID, location: event.location, notes: event.notes),
                                  eventID: id, occurrence: event.start, recurring: event.recurring)
    }

    func cancelEdit() { editing = nil; editProblem = nil }

    /// Saves the open editor. A problem stays in the editor; nothing is saved until it is fixed.
    func saveEdit() {
        guard let writer, let editing else { return }
        if let problem = editing.draft.problem { editProblem = problem; return }
        do {
            try writer.save(editing.draft, eventID: editing.eventID, occurrence: editing.occurrence, future: editing.recurring && editing.future)
            if let id = editing.draft.calendarID { defaults?.set(id, forKey: "calendarLastWritten") }
            self.editing = nil; editProblem = nil
            anchorIfHidden(editing.draft.start)
            changed()
        } catch { editProblem = error.localizedDescription }
    }

    /// Deletes the event waiting in `deleting`, after the user confirmed it.
    func confirmDelete(future: Bool) {
        guard let writer, let event = deleting, let id = event.localID else { deleting = nil; return }
        deleting = nil
        do {
            try writer.delete(eventID: id, occurrence: event.start, future: event.recurring && future)
            clearSelection(); editProblem = nil
            changed()
        } catch { editProblem = error.localizedDescription }
    }

    /// Moves a dropped event by whole quarter hours and days. A repeating event moves this one day only.
    func move(_ event: Event, minutes: Int, days: Int) {
        guard let writer, event.editable, let id = event.localID, minutes != 0 || days != 0 else { return }
        let end = event.allDay ? max(event.start, event.end.addingTimeInterval(-1)) : event.end
        let draft = CalendarEventDraft(title: event.title, start: event.start, end: end, allDay: event.allDay, calendarID: event.calendarID,
                                       location: event.location, notes: event.notes).moved(minutes: minutes, days: days)
        do {
            try writer.save(draft, eventID: id, occurrence: event.start, future: false)
            editProblem = nil
            changed()
        } catch { editProblem = error.localizedDescription }
    }

    /// Shows the day of a saved event when it is not on screen.
    private func anchorIfHidden(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        if !days.contains(day) { showDayKeepingMode(day) }
    }

    /// The store also posts its own change notice. Reading now keeps the grid in step at once.
    private func changed() {
        Self.clearCache()
        reload()
    }
}
