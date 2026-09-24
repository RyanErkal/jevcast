import AppKit
import EventKit
import SwiftUI

/// Calendar in the launcher panel: a month grid (the default), a week, and the event list.
/// ← and → switch between them; ↑ and ↓ move to the previous or next month or week.
/// The list is the source view the calendar used before, with its detail and verbs.
@MainActor
final class CalendarPage: ObservableObject, LauncherPage {
    enum Mode: String, CaseIterable { case month = "Month", week = "Week", list = "List" }
    struct Event: Identifiable, Equatable {
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
    @Published private(set) var events: [Event] = []
    @Published private(set) var problem: SourceProblem?
    @Published private(set) var filterText = ""
    private var work: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var calendar: Calendar { Calendar.current }

    init(list: SourcePage, readsEvents: Bool) {
        self.list = list; self.readsEvents = readsEvents
    }

    var canPopOut: Bool { list.canPopOut }
    func popOut() { list.popOut() }

    func opened() {
        mode = .month; anchor = Date()
        list.opened()
        load()
        // Changes made in Calendar show while the view is open.
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }
    func closed(handingOff: Bool) {
        list.closed(handingOff: handingOff)
        work?.cancel()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    func filter(_ text: String) {
        filterText = text
        list.filter(text)
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

    func setMode(_ next: Mode) { mode = next; load() }
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
    var days: [Date] {
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
    func events(on day: Date) -> [Event] {
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let words = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { $0.start < end && $0.end > day && (words.isEmpty || $0.title.lowercased().contains(words)) }
    }
    func inMonth(_ day: Date) -> Bool { mode == .week || calendar.isDate(day, equalTo: anchor, toGranularity: .month) }

    private func load() {
        guard mode != .list, readsEvents else { events = []; return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []
            problem = SourceProblem(text: "Allow Calendar access to see your events.", access: .calendars)
            return
        }
        problem = nil
        guard let start = days.first, let last = days.last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        work?.cancel()
        work = Task { @MainActor [weak self] in
            let store = Permissions.events
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            // Cancelled events and declined invitations are not on their day.
            let found = store.events(matching: predicate).filter { event in
                event.status != .canceled && !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { event in
                Event(id: (event.eventIdentifier ?? UUID().uuidString) + ":\(event.startDate.timeIntervalSince1970)",
                      title: event.title ?? "Untitled event", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                      color: event.calendar.map { Color(nsColor: $0.color) } ?? .accentColor)
            }
            guard !Task.isCancelled, let self else { return }
            self.events = found
        }
    }
    func grant() { Task { await Permissions.request(.calendars); load() } }

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
            ForEach(events.prefix(limit)) { event in
                HStack(spacing: 4) {
                    if event.allDay {
                        Text(event.title).lineLimit(1).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 3).fill(event.color.opacity(0.3)))
                    } else {
                        Circle().fill(event.color).frame(width: 6, height: 6)
                        if tall { Text(event.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary) }
                        Text(event.title).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .help(event.title + " · " + (event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)))
            }
            if events.count > limit {
                Text("+\(events.count - limit) more").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dimmed ? 0.6 : 1)
    }
}
