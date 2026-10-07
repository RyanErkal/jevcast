import AppKit
import Combine
import EventKit
import LauncherCore
import SwiftUI

/// Local Calendar and opt-in Google Calendar. Data is copied into values before drawing.
@MainActor
final class CalendarPage: ObservableObject, LauncherPage {
    /// In ← and → order. Calendar opens on 3 Days.
    enum Mode: String, CaseIterable { case day = "Day", threeDays = "3 Days", week = "Week", month = "Month", list = "List" }
    enum Source: String { case mac = "On This Mac", google = "Google" }
    struct Event: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: Color
        var notes = ""
        var location = ""
        var calendarName = ""
        var organizer = ""
        var guests: [CalendarGuest] = []
        var attachments: [CalendarAttachment] = []
        var meetingURL: URL?
        var webURL: URL?
        var localID: String?
        var timeZone: String?
    }

    let id = ViewID.calendar
    private let list: SourcePage
    /// False for snapshot runs, which never read real events.
    private let readsEvents: Bool
    @Published private(set) var mode: Mode = .threeDays
    @Published private(set) var source: Source = .mac
    @Published private(set) var selectedEvent: Event?
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    let google: GoogleCalendarAccount?
    private let defaults: UserDefaults?
    private let hideLauncher: () -> Void
    private let openSignIn: @MainActor (GoogleCalendarAccount) -> Void
    /// Any day inside the month or week on screen.
    @Published private(set) var anchor = Date()
    /// The days on screen and each day's events, worked out once per change, not per redraw.
    @Published private(set) var days: [Date] = []
    @Published private(set) var byDay: [Date: [Event]] = [:]
    @Published private(set) var problem: SourceProblem?
    private var events: [Event] = []
    private var filterText = ""
    private var work: Task<Void, Never>?
    private var fetchTask: Task<[Event], Never>?
    private var changeObserver: NSObjectProtocol?
    private var changeWork: Task<Void, Never>?
    /// Fetched windows, newest last, kept across openings so the view shows at once. Each window covers
    /// the month on screen and the months either side, so ↑ and ↓ and a week inside it need no fetch.
    /// Cleared when Calendar changes.
    private static var cache: [(range: DateInterval, events: [Event])] = []
    private static var cacheObserver: NSObjectProtocol?
    private var listOpened = false
    private var calendar: Calendar { Calendar.current }

    init(list: SourcePage, readsEvents: Bool, google: GoogleCalendarAccount? = nil, defaults: UserDefaults? = nil,
         hideLauncher: @escaping () -> Void = {},
         openSignIn: @escaping @MainActor (GoogleCalendarAccount) -> Void = { CalendarGoogleSignInWindow.shared.show(account: $0) }) {
        self.list = list; self.readsEvents = readsEvents
        self.google = google ?? (readsEvents ? .shared : nil)
        self.defaults = defaults ?? (readsEvents ? .standard : nil)
        self.hideLauncher = hideLauncher; self.openSignIn = openSignIn
        if self.google?.connected == true, self.defaults?.string(forKey: "calendarSource") == Source.google.rawValue { source = .google }
    }

    var canPopOut: Bool { source == .google || list.canPopOut }
    var openTitle: String { selectedEvent.map { $0.meetingURL == nil ? "Open in Calendar" : "Join Call" } ?? "Details" }
    var footerChanges: AnyPublisher<Void, Never> { $selectedEvent.map { _ in () }.eraseToAnyPublisher() }
    func popOut() {
        guard readsEvents else { return }
        if source == .google { Frontmost.open(URL(string: "https://calendar.google.com/")!) } else { list.popOut() }
    }
    func select(_ event: Event) { selectedEvent = event }
    func signIn() {
        guard let google else { return }
        // Hide first, so app activation focuses the sign-in window instead of the launcher.
        hideLauncher()
        openSignIn(google)
    }
    func clearSelection() { selectedEvent = nil }
    func use(_ next: Source) {
        source = next; selectedEvent = nil
        defaults?.set(next.rawValue, forKey: "calendarSource")
        events = []; byDay = [:]; problem = nil; errorMessage = nil
        if next == .mac, mode == .list, !listOpened { listOpened = true; list.opened() }
        load()
    }
    func refresh() { Self.cache = []; load(refreshGoogle: true) }
    func showDay(_ day: Date) { anchor = day; mode = .day; selectedEvent = nil; load() }
    var displayedEvents: [Event] {
        var seen = Set<String>()
        return days.flatMap { events(on: $0) }.filter { seen.insert($0.id).inserted }
    }

    func open(_ url: URL) { if readsEvents { Frontmost.open(url) } }
    func openInCalendar(_ event: Event) {
        guard readsEvents else { return }
        if let id = event.localID, let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") { open(url) }
        else if let web = event.webURL { open(web) }
        else { CalendarSource.openApp("com.apple.iCal") }
    }

    func opened() {
        mode = .threeDays; anchor = Date(); listOpened = false; selectedEvent = nil
        if readsEvents { Self.watchStore() }
        load()
        // Changes made in Calendar show while the view is open. A burst of changes reloads once.
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeWork?.cancel()
                self.changeWork = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled, let self else { return }
                    Self.cache = []; if self.source == .mac { self.load() }
                }
            }
        }
    }
    func closed(handingOff: Bool) {
        if listOpened { list.closed(handingOff: handingOff) }
        work?.cancel(); fetchTask?.cancel(); changeWork?.cancel()
        loading = false
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    func filter(_ text: String) {
        guard text != filterText else { return }
        filterText = text
        list.filter(text)
        if mode != .list || source == .google { group() }
    }

    func handle(_ key: PageKey) -> Bool {
        switch (mode, key) {
        case (_, .left): cycle(-1); return true
        case (_, .right): cycle(1); return true
        case (.list, _) where source == .mac: return list.handle(key)
        case (_, .up): step(-1); return true
        case (_, .down): step(1); return true
        case (_, .open):
            if let event = selectedEvent {
                if let url = event.meetingURL { open(url) } else { openInCalendar(event) }
            }
            else if let event = events(on: calendar.startOfDay(for: anchor)).first ?? displayedEvents.first { select(event) }
            return true
        case (_, .delete): return true
        }
    }
    func back() -> Bool {
        if selectedEvent != nil { selectedEvent = nil; return true }
        return mode == .list && source == .mac ? list.back() : false
    }

    func setMode(_ next: Mode) {
        guard next != mode else { return }
        mode = next; selectedEvent = nil
        // The list loads its rows the first time it shows, not while the grid is on screen.
        if next == .list, source == .mac, !listOpened { listOpened = true; list.opened() }
        load()
    }
    func cycle(_ delta: Int) {
        let all = Mode.allCases
        let index = all.firstIndex(of: mode) ?? 0
        setMode(all[(index + delta + all.count) % all.count])
    }
    /// The previous or next day, three days, week, or month.
    func step(_ delta: Int) {
        selectedEvent = nil
        let (unit, size): (Calendar.Component, Int) = switch mode {
        case .day: (.day, 1)
        case .threeDays: (.day, 3)
        case .month: (.month, 1)
        case .week, .list: (.weekOfYear, 1)
        }
        anchor = calendar.date(byAdding: unit, value: delta * size, to: anchor) ?? anchor
        load()
    }
    func today() { anchor = Date(); selectedEvent = nil; load() }

    /// The days on screen: whole weeks covering the month, the one week, or days from the anchor.
    private func computeDays() -> [Date] {
        let range: DateInterval?
        if mode == .day || mode == .threeDays {
            let first = calendar.startOfDay(for: anchor)
            range = calendar.date(byAdding: .day, value: mode == .day ? 1 : 3, to: first).map { DateInterval(start: first, end: $0) }
        } else if mode == .week || mode == .list {
            range = calendar.dateInterval(of: .weekOfYear, for: anchor)
        } else if let month = calendar.dateInterval(of: .month, for: anchor),
                  let first = calendar.dateInterval(of: .weekOfYear, for: month.start),
                  let last = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1)) {
            range = DateInterval(start: first.start, end: last.end)
        } else { range = nil }
        guard let range else { return [] }
        var result: [Date] = []
        var day = range.start
        while day < range.end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? range.end
        }
        return result
    }
    /// The month on screen, or both months when the days cross into the next one.
    var title: String {
        guard mode != .month, let first = days.first, let last = days.last,
              !calendar.isDate(first, equalTo: last, toGranularity: .month) else { return (mode == .month ? anchor : days.first ?? anchor).formatted(.dateTime.month(.wide).year()) }
        let sameYear = calendar.isDate(first, equalTo: last, toGranularity: .year)
        return first.formatted(sameYear ? .dateTime.month(.abbreviated) : .dateTime.month(.abbreviated).year())
            + " – " + last.formatted(.dateTime.month(.abbreviated).year())
    }
    func events(on day: Date) -> [Event] { byDay[day] ?? [] }
    /// Puts each event on every day it covers, with the filter applied. One pass over the events.
    private func group() {
        let words = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [Date: [Event]] = [:]
        guard let first = days.first, let last = days.last else { byDay = [:]; return }
        let calendar = calendar
        for event in events where words.isEmpty || event.title.lowercased().contains(words) {
            var day = max(calendar.startOfDay(for: event.start), first)
            // An event that ends exactly at midnight does not show on the next day.
            let end = event.end > event.start ? event.end : event.start.addingTimeInterval(1)
            while day < end && day <= last {
                result[day, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        byDay = result
    }
    func inMonth(_ day: Date) -> Bool { mode != .month || calendar.isDate(day, equalTo: anchor, toGranularity: .month) }

    private func load(refreshGoogle: Bool = false) {
        work?.cancel(); fetchTask?.cancel(); loading = false
        errorMessage = nil; problem = nil
        guard mode != .list || source == .google else { return }
        days = computeDays()
        guard readsEvents else { events = Self.demoEvents(around: anchor); group(); return }
        if source == .google { loadGoogle(refreshCalendars: refreshGoogle); return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []; group()
            problem = SourceProblem(text: "Allow Calendar access to see your events.", access: .calendars)
            return
        }
        problem = nil
        guard let start = days.first, let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        let range = DateInterval(start: start, end: end)
        let window = fetchWindow(covering: range)
        work?.cancel(); fetchTask?.cancel()
        let shown = Self.cached(range)
        if let shown { events = shown; group() }
        // A cached range shows at once. The wider window is fetched in the background when missing,
        // so the next step is cached too. On a miss the old events stay until the fetch arrives.
        if shown != nil, Self.cached(window) != nil { return }
        nonisolated(unsafe) let store = Permissions.events
        let task = Task.detached(priority: shown == nil ? .userInitiated : .utility) { Self.fetch(store, window) }
        fetchTask = task
        work = Task { @MainActor [weak self] in
            let found = await task.value
            guard !Task.isCancelled, let self else { return }
            Self.store(window, found)
            let visible = Self.cached(range) ?? found
            self.events = visible; self.group()
        }
    }
    /// The month on screen with a month either side, in whole weeks.
    private func fetchWindow(covering range: DateInterval) -> DateInterval {
        guard let month = calendar.dateInterval(of: .month, for: anchor),
              let before = calendar.date(byAdding: .month, value: -1, to: month.start),
              let after = calendar.date(byAdding: .month, value: 2, to: month.start),
              let first = calendar.dateInterval(of: .weekOfYear, for: before),
              let last = calendar.dateInterval(of: .weekOfYear, for: after) else { return range }
        return DateInterval(start: min(first.start, range.start), end: max(last.end, range.end))
    }
    /// Events in `range` from a cached window that covers it, in the fetched order.
    private static func cached(_ range: DateInterval) -> [Event]? {
        guard let hit = cache.last(where: { $0.range.start <= range.start && $0.range.end >= range.end }) else { return nil }
        if hit.range == range { return hit.events }
        return hit.events.filter { $0.start < range.end && ($0.end > range.start || $0.start >= range.start) }
    }
    private static func store(_ range: DateInterval, _ events: [Event]) {
        cache.removeAll { $0.range == range }
        cache.append((range, events))
        if cache.count > 6 { cache.removeFirst(cache.count - 6) }
    }
    /// Clears the cache when Calendar changes, also while the view is closed.
    private static func watchStore() {
        guard cacheObserver == nil else { return }
        cacheObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { cache = [] }
        }
    }
    /// Reads EventKit off the main thread. Cancelled events and declined invitations are left out.
    nonisolated private static func fetch(_ store: EKEventStore, _ range: DateInterval) -> [Event] {
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        var colours: [String: Color] = [:]
        return store.events(matching: predicate).filter { event in
            event.status != .canceled && !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
        }
        .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
        .map { event in
            let key = event.calendar?.calendarIdentifier ?? ""
            let colour = colours[key] ?? color(of: event.calendar)
            colours[key] = colour
            return Event(id: (event.eventIdentifier ?? UUID().uuidString) + ":\(event.startDate.timeIntervalSince1970)",
                         title: event.title ?? "Untitled event", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                         color: colour, notes: event.notes ?? "", location: event.location ?? "", calendarName: event.calendar?.title ?? "",
                         organizer: event.organizer?.name ?? event.organizer?.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") ?? "",
                         guests: (event.attendees ?? []).map { CalendarGuest(name: $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""), response: Self.response($0.participantStatus)) },
                         meetingURL: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
                         webURL: CalendarLinks.web(event.url?.absoluteString), localID: event.eventIdentifier, timeZone: event.timeZone?.identifier)
        }
    }
    /// The calendar's own colour. `cgColor` keeps it in its colour space; a missing or
    /// near-black colour falls back to the accent colour so the event never draws as a black dot.
    nonisolated static func color(of calendar: EKCalendar?) -> Color {
        guard let cg = calendar?.cgColor, let rgb = NSColor(cgColor: cg)?.usingColorSpace(.sRGB),
              rgb.redComponent + rgb.greenComponent + rgb.blueComponent > 0.15 else { return .accentColor }
        return Color(nsColor: rgb)
    }
    nonisolated private static func response(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        default: return "needsAction"
        }
    }
    func grant() { Task { await Permissions.request(.calendars); load() } }

    /// Invented events for `--snapshot-ui`, so the layout can be checked without real data.
    private static func demoEvents(around anchor: Date) -> [Event] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: anchor)
        let items: [(Int, Int, Int, String, Color, Bool)] = [
            (0, 9, 30, "Team stand-up", .blue, false), (0, 13, 60, "Lunch with Sam", .orange, false),
            (0, 16, 45, "Design review", .purple, false), (0, 18, 30, "Gym", .green, false),
            (1, 0, 0, "Holiday", .red, true), (2, 11, 60, "Dentist", .teal, false),
            (-2, 10, 90, "Workshop", .pink, false), (-1, 15, 30, "Call with Alex", .blue, false),
            (2, 11, 45, "Planning", .indigo, false)
        ]
        return items.enumerated().compactMap { index, item in
            guard let day = cal.date(byAdding: .day, value: item.0, to: today),
                  let start = cal.date(byAdding: .minute, value: item.1 * 60, to: day) else { return nil }
            let end = item.5 ? cal.date(byAdding: .day, value: 1, to: day)! : start.addingTimeInterval(Double(item.2) * 60)
            return Event(id: "demo\(index)", title: item.3, start: start, end: end, allDay: item.5, color: item.4,
                         notes: index == 0 ? "Review this week's priorities.\n\nMeeting notes\n• Confirm the launch checklist\n• Assign next steps and owners\n• Share the final designs" : "",
                         location: index == 0 ? "Google Meet" : "", calendarName: "Work", organizer: index == 0 ? "Sam Taylor" : "",
                         guests: index == 0 ? [CalendarGuest(name: "Alex Morgan", response: "accepted"), CalendarGuest(name: "Sam Taylor", response: "accepted")] : [],
                         attachments: index == 0 ? [CalendarAttachment(title: "Meeting notes", url: URL(string: "https://docs.google.com/document/d/demo")!)] : [],
                         meetingURL: index == 0 ? URL(string: "https://meet.google.com/abc-defg-hij") : nil,
                         webURL: index == 0 ? URL(string: "https://calendar.google.com/") : nil)
        }
    }

    func content() -> AnyView { AnyView(CalendarPageView(page: self, list: list)) }

    private func loadGoogle(refreshCalendars: Bool) {
        guard let google, google.connected else { events = []; group(); errorMessage = GoogleCalendarError.signInRequired.localizedDescription; return }
        guard let start = days.first, let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        let range = DateInterval(start: start, end: end)
        events = []; group(); loading = true
        work = Task { @MainActor [weak self] in
            do {
                let found = try await google.load(range, refreshCalendars: refreshCalendars)
                guard !Task.isCancelled, let self else { return }
                let calendars = Dictionary(uniqueKeysWithValues: google.calendars.map { ($0.id, $0) })
                self.events = found.map { event in
                    let info = calendars[event.calendarID]
                    return Event(id: event.id, title: event.title, start: event.start, end: event.end, allDay: event.allDay,
                        color: Self.googleColor(info?.backgroundColor), notes: event.notes, location: event.location, calendarName: info?.summary ?? "Google Calendar",
                        organizer: event.organizer, guests: event.guests, attachments: event.attachments, meetingURL: event.meetingURL, webURL: event.webURL, timeZone: event.timeZone)
                }
                self.group(); self.loading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.loading = false; self.errorMessage = error.localizedDescription
            }
        }
    }

    static func googleColor(_ hex: String?) -> Color {
        guard let hex, hex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
              let value = UInt32(hex.dropFirst(), radix: 16) else { return .blue }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
