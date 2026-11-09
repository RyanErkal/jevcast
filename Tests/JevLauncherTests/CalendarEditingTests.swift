import XCTest
import SwiftUI
import LauncherCore
@testable import JevLauncher

@MainActor
private final class FakeCalendarWriter: CalendarWriting {
    var isAllowed = true
    var saved: [(draft: CalendarEventDraft, eventID: String?, occurrence: Date?, future: Bool)] = []
    var deleted: [(eventID: String, occurrence: Date?, future: Bool)] = []
    var failure: Error?
    func calendars() -> [WritableCalendar] { [WritableCalendar(id: "work", title: "Work", account: "iCloud", color: .blue),
                                              WritableCalendar(id: "home", title: "Home", account: "iCloud", color: .green)] }
    var defaultCalendarID: String? { "work" }
    func allowed() async -> Bool { isAllowed }
    func save(_ draft: CalendarEventDraft, eventID: String?, occurrence: Date?, future: Bool) throws {
        if let failure { throw failure }
        saved.append((draft, eventID, occurrence, future))
    }
    func delete(eventID: String, occurrence: Date?, future: Bool) throws {
        if let failure { throw failure }
        deleted.append((eventID, occurrence, future))
    }
}

@MainActor private final class EditingTestPasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    func string() -> String? { nil }
    func write(_ text: String) -> Int { changeCount += 1; return changeCount }
}

@MainActor
final class CalendarEditingTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "CalendarEditingTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func page(_ writer: FakeCalendarWriter, openMail: ((String) -> Void)? = nil) -> CalendarPage {
        let preferences = Preferences(defaults: defaults); preferences.voiceEnabled = false; preferences.jevEnabled = false
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false), keys: JevKeyCache(key: nil),
                                  clipboard: ClipboardHistory(pasteboard: EditingTestPasteboard()))
        let list = SourcePage(.calendar, source: nil, model: model, hasDetail: true, emptyText: "")
        return CalendarPage(list: list, readsEvents: false, defaults: defaults, writer: writer, openMail: openMail)
    }

    private func event(_ id: String, hour: Int, editable: Bool = true, recurring: Bool = false) -> CalendarPage.Event {
        let start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        return CalendarPage.Event(id: id + ":0", title: "Event " + id, start: start, end: start.addingTimeInterval(1800), allDay: false, color: .blue,
                                  notes: "Bring notes", location: "Room 4", localID: id, editable: editable, recurring: recurring, calendarID: "home")
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

    func testNewEventOpensTheEditorAndSavesToTheChosenCalendar() async {
        let writer = FakeCalendarWriter(), page = page(writer)
        page.opened(); defer { page.closed(handingOff: false) }
        page.beginCreate()
        await settle()
        var editing = try! XCTUnwrap(page.editing)
        XCTAssertTrue(editing.isNew); XCTAssertEqual(editing.draft.calendarID, "work")
        XCTAssertTrue(page.isTyping, "The editor takes the keys.")
        page.saveEdit()
        XCTAssertEqual(page.editProblem, "Add a title."); XCTAssertTrue(writer.saved.isEmpty); XCTAssertNotNil(page.editing)
        editing.draft.title = "Planning"; editing.draft.calendarID = "home"
        page.editing = editing
        page.saveEdit()
        XCTAssertNil(page.editing); XCTAssertNil(page.editProblem)
        XCTAssertEqual(writer.saved.count, 1)
        XCTAssertEqual(writer.saved[0].draft.title, "Planning"); XCTAssertNil(writer.saved[0].eventID)
        XCTAssertEqual(defaults.string(forKey: "calendarLastWritten"), "home", "The next new event starts on the calendar last used.")
    }

    func testWithoutCalendarAccessNothingOpensAndTheReasonShows() async {
        let writer = FakeCalendarWriter(), page = page(writer)
        writer.isAllowed = false
        page.opened(); defer { page.closed(handingOff: false) }
        page.beginCreate()
        await settle()
        XCTAssertNil(page.editing); XCTAssertNotNil(page.editProblem)
    }

    func testEditChangesOnlyTheChosenOccurrenceUnlessFutureIsChosen() {
        let writer = FakeCalendarWriter(), page = page(writer)
        page.opened(); defer { page.closed(handingOff: false) }
        let repeating = event("weekly", hour: 10, recurring: true)
        page.setEvents([repeating])
        page.beginEdit(repeating)
        var editing = try! XCTUnwrap(page.editing)
        XCTAssertEqual(editing.eventID, "weekly"); XCTAssertEqual(editing.occurrence, repeating.start); XCTAssertEqual(editing.draft.location, "Room 4")
        editing.draft.title = "Weekly sync"
        page.editing = editing
        page.saveEdit()
        XCTAssertEqual(writer.saved.last?.future, false)
        page.beginEdit(repeating)
        page.editing?.future = true
        page.saveEdit()
        XCTAssertEqual(writer.saved.last?.future, true); XCTAssertEqual(writer.saved.last?.occurrence, repeating.start)
        let readOnly = event("holiday", hour: 12, editable: false)
        page.beginEdit(readOnly)
        XCTAssertNil(page.editing, "An event Jevcast cannot change never opens the editor.")
    }

    func testDeleteNeedsAConfirmationAndEscapeCancelsIt() {
        let writer = FakeCalendarWriter(), page = page(writer)
        page.opened(); defer { page.closed(handingOff: false) }
        let first = event("a", hour: 9), second = event("b", hour: 11), locked = event("c", hour: 13, editable: false)
        page.setEvents([first, second, locked])
        page.select(first)
        XCTAssertTrue(page.handle(.delete))
        XCTAssertEqual(page.deleting?.id, first.id); XCTAssertTrue(writer.deleted.isEmpty, "⌫ only asks.")
        XCTAssertTrue(page.back()); XCTAssertNil(page.deleting); XCTAssertTrue(writer.deleted.isEmpty)
        XCTAssertTrue(page.handle(.delete))
        page.confirmDelete(future: true)
        XCTAssertEqual(writer.deleted.count, 1); XCTAssertEqual(writer.deleted[0].eventID, "a")
        XCTAssertFalse(writer.deleted[0].future, "An event that does not repeat has no later events to remove.")
        page.setEvents([first, second, locked])
        page.select(locked)
        XCTAssertTrue(page.handle(.delete)); XCTAssertNil(page.deleting, "A read-only event cannot be deleted.")
    }

    func testArrowsWalkEventsWhileOneIsSelectedAndMoveSavesTheNewTime() {
        let writer = FakeCalendarWriter(), page = page(writer)
        page.opened(); defer { page.closed(handingOff: false) }
        let first = event("a", hour: 9), second = event("b", hour: 11)
        page.setEvents([second, first])
        let firstDay = page.days.first
        page.select(first)
        XCTAssertTrue(page.handle(.down)); XCTAssertEqual(page.selectedEvent?.id, second.id)
        XCTAssertTrue(page.handle(.down)); XCTAssertEqual(page.selectedEvent?.id, second.id, "The last event stays selected.")
        XCTAssertTrue(page.handle(.up)); XCTAssertEqual(page.selectedEvent?.id, first.id)
        XCTAssertEqual(page.days.first, firstDay, "The days do not step while an event is selected.")
        page.move(first, minutes: 45, days: 1)
        XCTAssertEqual(writer.saved.count, 1)
        XCTAssertEqual(writer.saved[0].draft.start, Calendar.current.date(byAdding: .day, value: 1, to: first.start)!.addingTimeInterval(45 * 60))
        XCTAssertEqual(writer.saved[0].draft.end.timeIntervalSince(writer.saved[0].draft.start), 1800)
        XCTAssertEqual(writer.saved[0].eventID, "a"); XCTAssertFalse(writer.saved[0].future)
        page.move(first, minutes: 0, days: 0)
        XCTAssertEqual(writer.saved.count, 1, "A drop in place saves nothing.")
    }

    func testAFailedSaveKeepsTheEditorAndShowsTheReason() {
        let writer = FakeCalendarWriter(), page = page(writer)
        page.opened(); defer { page.closed(handingOff: false) }
        let item = event("a", hour: 9)
        page.setEvents([item]); page.beginEdit(item)
        writer.failure = CalendarWriteError.missing
        page.saveEdit()
        XCTAssertNotNil(page.editing); XCTAssertEqual(page.editProblem, CalendarWriteError.missing.localizedDescription)
        XCTAssertTrue(page.back()); XCTAssertNil(page.editing); XCTAssertNil(page.editProblem)
    }

    func testTheLastViewComesBackAndTheFilterReadsPlacesAndNotes() {
        let writer = FakeCalendarWriter(), first = page(writer)
        first.opened()
        first.setMode(.week)
        first.closed(handingOff: false)
        let second = page(writer)
        second.opened(); defer { second.closed(handingOff: false) }
        XCTAssertEqual(second.mode, .week, "Calendar opens on the view last used.")
        second.setEvents([event("a", hour: 9)])
        second.filter("room 4")
        XCTAssertEqual(second.displayedEvents.count, 1)
        second.filter("budget")
        XCTAssertEqual(second.displayedEvents.count, 0)
    }

    func testFurtherGoogleAccountsHaveTheirOwnStorageAndLeaveWhenDisconnected() throws {
        func account(_ slot: String) -> GoogleCalendarAccount {
            GoogleCalendarAccount(slot: slot, defaults: defaults, readToken: { nil }, saveToken: { _ in }, deleteToken: {}, readSecret: { nil }, writeSecret: { _ in })
        }
        defaults.set(true, forKey: "calendarGoogleConnected")
        let registry = GoogleCalendarAccounts(primary: account(""), defaults: defaults, make: account)
        XCTAssertEqual(registry.all.count, 1); XCTAssertEqual(registry.connected.count, 1)
        let second = registry.accountForSignIn()
        XCTAssertFalse(second.slot.isEmpty); XCTAssertTrue(GoogleCalendarAccounts.validSlot(second.slot))
        XCTAssertTrue(registry.accountForSignIn() === second, "A free account is reused, not added again.")
        XCTAssertEqual(defaults.stringArray(forKey: "calendarGoogleSlots"), [second.slot])
        // A second sign-in writes only names that end in its own ID.
        defaults.set(true, forKey: "calendarGoogleConnected." + second.slot)
        let reopened = GoogleCalendarAccounts(primary: account(""), defaults: defaults, make: account)
        XCTAssertEqual(reopened.connected.map(\.slot), ["", second.slot])
        try reopened.disconnect(reopened.all[1])
        XCTAssertEqual(reopened.all.map(\.slot), [""], "A disconnected further account leaves the list.")
        XCTAssertTrue(defaults.bool(forKey: "calendarGoogleConnected"), "The first account stays connected.")
        XCTAssertEqual(defaults.stringArray(forKey: "calendarGoogleSlots"), [])
        XCTAssertFalse(GoogleCalendarAccounts.validSlot("../x")); XCTAssertFalse(GoogleCalendarAccounts.validSlot(""))
    }
}
