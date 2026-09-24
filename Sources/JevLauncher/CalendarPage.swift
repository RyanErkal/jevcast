import AppKit
import EventKit
import SwiftUI

/// Calendar in the launcher panel: a month grid (the default), a week, and the event list.
/// ← and → switch between them; ↑ and ↓ move to the previous or next month or week.
/// The list is the source view the calendar used before, with its detail and verbs.
@MainActor
final class CalendarPage: ObservableObject, LauncherPage {
    enum Mode: String, CaseIterable { case month = "Month", week = "Week", list = "List" }
    struct Event: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: Color
    }

    let id = ViewID.calendar
    private let list: SourcePage
    /// False for snapshot runs, which never read real events.
    private let readsEvents: Bool
    @Published private(set) var mode: Mode = .month
    /// Any day inside the month or week on screen.
    @Published private(set) var anchor = Date()
    /// The days on screen and each day's events, worked out once per change, not per redraw.
    @Published private(set) var days: [Date] = []
    @Published private(set) var byDay: [Date: [Event]] = [:]
    @Published private(set) var problem: SourceProblem?
    private var events: [Event] = []
    private var filterText = ""
    private var work: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var changeWork: Task<Void, Never>?
    /// Fetched ranges, so going back to a month or week shows at once. Cleared when Calendar changes.
    private var cache: [DateInterval: [Event]] = [:]
    private var listOpened = false
    private var calendar: Calendar { Calendar.current }

    init(list: SourcePage, readsEvents: Bool) {
        self.list = list; self.readsEvents = readsEvents
    }

    var canPopOut: Bool { list.canPopOut }
    func popOut() { list.popOut() }

    func opened() {
        mode = .month; anchor = Date(); cache = [:]; listOpened = false
        load()
        // Changes made in Calendar show while the view is open. A burst of changes reloads once.
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeWork?.cancel()
                self.changeWork = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.cache = [:]; self.load()
                }
            }
        }
    }
    func closed(handingOff: Bool) {
        if listOpened { list.closed(handingOff: handingOff) }
        work?.cancel(); changeWork?.cancel()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    func filter(_ text: String) {
        filterText = text
        list.filter(text)
        group()
    }

    func handle(_ key: PageKey) -> Bool {
        switch (mode, key) {
        case (_, .left): cycle(-1); return true
        case (_, .right): cycle(1); return true
        case (.list, _): return list.handle(key)
        case (_, .up): step(-1); return true
        case (_, .down): step(1); return true
        case (_, .open): CalendarSource.openApp("com.apple.iCal"); return true
        case (_, .delete): return true
        }
    }
    func back() -> Bool { mode == .list ? list.back() : false }

    func setMode(_ next: Mode) {
        guard next != mode else { return }
        mode = next
        // The list loads its rows the first time it shows, not while the grid is on screen.
        if next == .list, !listOpened { listOpened = true; list.opened() }
        load()
    }
    func cycle(_ delta: Int) {
        let all = Mode.allCases
        let index = all.firstIndex(of: mode) ?? 0
        setMode(all[(index + delta + all.count) % all.count])
    }
    /// The previous or next month or week.
    func step(_ delta: Int) {
        anchor = calendar.date(byAdding: mode == .week ? .weekOfYear : .month, value: delta, to: anchor) ?? anchor
        load()
    }
    func today() { anchor = Date(); load() }

    /// The days on screen: whole weeks covering the month, or the one week.
    private func computeDays() -> [Date] {
        let range: DateInterval?
        if mode == .week {
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
    var title: String {
        if mode == .week, let first = days.first, let last = days.last {
            return first.formatted(.dateTime.day().month(.abbreviated)) + " – " + last.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return anchor.formatted(.dateTime.month(.wide).year())
    }
    func events(on day: Date) -> [Event] { byDay[day] ?? [] }
    /// Puts each event on every day it covers, with the filter applied. One pass over the events.
    private func group() {
        let words = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [Date: [Event]] = [:]
        guard let first = days.first, let last = days.last else { byDay = [:]; return }
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
    func inMonth(_ day: Date) -> Bool { mode == .week || calendar.isDate(day, equalTo: anchor, toGranularity: .month) }

    private func load() {
        guard mode != .list else { return }
        days = computeDays()
        guard readsEvents else { events = Self.demoEvents(around: anchor); group(); return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []; group()
            problem = SourceProblem(text: "Allow Calendar access to see your events.", access: .calendars)
            return
        }
        problem = nil
        guard let start = days.first, let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        let range = DateInterval(start: start, end: end)
        work?.cancel()
        if let cached = cache[range] { events = cached; group(); return }
        // Keep the old events on screen until the new range arrives, so the grid never flashes empty.
        nonisolated(unsafe) let store = Permissions.events
        work = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.fetch(store, range) }.value
            guard !Task.isCancelled, let self else { return }
            self.cache[range] = found
            self.events = found
            self.group()
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
                         color: colour)
        }
    }
    /// The calendar's own colour. `cgColor` keeps it in its colour space; a missing or
    /// near-black colour falls back to the accent colour so the event never draws as a black dot.
    nonisolated static func color(of calendar: EKCalendar?) -> Color {
        guard let cg = calendar?.cgColor, let rgb = NSColor(cgColor: cg)?.usingColorSpace(.sRGB),
              rgb.redComponent + rgb.greenComponent + rgb.blueComponent > 0.15 else { return .accentColor }
        return Color(nsColor: rgb)
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
            (-2, 10, 90, "Workshop", .pink, false), (-1, 15, 30, "Call with Alex", .blue, false)
        ]
        return items.enumerated().compactMap { index, item in
            guard let day = cal.date(byAdding: .day, value: item.0, to: today),
                  let start = cal.date(byAdding: .minute, value: item.1 * 60, to: day) else { return nil }
            let end = item.5 ? cal.date(byAdding: .day, value: 1, to: day)! : start.addingTimeInterval(Double(item.2) * 60)
            return Event(id: "demo\(index)", title: item.3, start: start, end: end, allDay: item.5, color: item.4)
        }
    }

    func content() -> AnyView { AnyView(CalendarPageView(page: self, list: list)) }
}

private struct CalendarPageView: View {
    @ObservedObject var page: CalendarPage
    let list: SourcePage

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch page.mode {
            case .list: list.content()
            case .month: grid(columns: 7, tall: false)
            case .week: grid(columns: 7, tall: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if page.mode != .list {
                Button { page.step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Previous (↑)")
                Button { page.step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).help("Next (↓)")
                Text(page.title).font(.system(size: 15, weight: .semibold))
                Button("Today") { page.today() }.controlSize(.small)
            } else {
                Text("Upcoming").font(.system(size: 15, weight: .semibold))
            }
            Spacer()
            Picker("", selection: Binding(get: { page.mode }, set: { page.setMode($0) })) {
                ForEach(CalendarPage.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("← and → switch views")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private func grid(columns: Int, tall: Bool) -> some View {
        if let problem = page.problem {
            VStack(spacing: 10) {
                Text(problem.text).foregroundStyle(.secondary)
                Button("Allow Access") { page.grant() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let days = page.days
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(days.prefix(7), id: \.self) { day in
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 5)
                Divider()
                let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
                VStack(spacing: 0) {
                    ForEach(weeks, id: \.first) { week in
                        HStack(spacing: 0) {
                            ForEach(week, id: \.self) { day in
                                DayCell(day: day, events: page.events(on: day), dimmed: !page.inMonth(day), limit: tall ? 14 : 3, tall: tall)
                                if day != week.last { Divider() }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        if week.first != weeks.last?.first { Divider() }
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let events: [CalendarPage.Event]
    let dimmed: Bool
    let limit: Int
    let tall: Bool
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 12, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : dimmed ? Color.secondary.opacity(0.5) : Color.primary)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Circle().fill(isToday ? Color.red : .clear))
            }
            ForEach(events.prefix(limit)) { event in EventChip(event: event, showsTime: tall) }
            if events.count > limit {
                Text("+\(events.count - limit) more").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isToday ? Color.red.opacity(0.06) : .clear)
        .opacity(dimmed ? 0.55 : 1)
    }
}

/// One event, styled like Calendar: all-day events as a filled bar, timed events as a tinted
/// chip with a bar in the calendar's colour on the left.
private struct EventChip: View {
    let event: CalendarPage.Event
    let showsTime: Bool
    private var time: String { event.start.formatted(date: .omitted, time: .shortened) }

    var body: some View {
        Group {
            if event.allDay {
                Text(event.title).fontWeight(.medium).lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(event.color.opacity(0.85)))
            } else if showsTime {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.title).fontWeight(.medium).lineLimit(2)
                        Text(time).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3).padding(.trailing, 4)
                // The colour bar would otherwise stretch the chip to the full day.
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 4).fill(event.color.opacity(0.16)))
            } else {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3, height: 12)
                    // Month cells are narrow: the title gets the room, and the time shows on hover.
                    Text(event.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(event.color.opacity(0.12)))
            }
        }
        .font(.system(size: 11))
        .help(event.title + " · " + (event.allDay ? "All day" : time))
    }
}
