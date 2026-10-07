import LauncherCore
import SwiftUI

struct CalendarPageView: View {
    @ObservedObject var page: CalendarPage
    let list: SourcePage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The event details beside the calendar: 260 points in the smallest panel, up to 320.
    static func inspectorWidth(_ total: CGFloat) -> CGFloat { min(320, max(260, (total * 0.26).rounded())) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let problem = page.problem {
                VStack(spacing: 12) {
                    Text(problem.text).foregroundStyle(.secondary)
                    Button("Allow Calendar Access") { page.grant() }
                    Button("Connect Google Calendar", action: signIn).disabled(page.google == nil)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = page.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                    HStack {
                        Button("Refresh") { page.refresh() }
                        Button("Sign in with Google", action: signIn).disabled(page.google == nil)
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if page.mode == .list && page.source == .mac {
                list.content()
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            switch page.mode {
                            case .month: month
                            case .list: googleList
                            case .day, .threeDays, .week: CalendarTimeGrid(page: page)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        if let event = page.selectedEvent {
                            Divider()
                            CalendarEventDetail(event: event, close: page.clearSelection, open: page.open, openCalendar: { page.openInCalendar(event) })
                                .frame(width: Self.inspectorWidth(geometry.size.width))
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: page.selectedEvent?.id)
                }
            }
        }
    }

    private func signIn() {
        page.signIn()
    }

    /// One row: the month and the steps on the left; the source, refresh, and views on the right.
    private var header: some View {
        HStack(spacing: 10) {
            if page.mode == .list && page.source == .mac {
                Text("Upcoming").font(.system(size: 15, weight: .semibold))
            } else {
                Text(page.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                stepper
            }
            Spacer(minLength: 8)
            if page.loading { ProgressView().controlSize(.mini).help("Loading events") }
            Group {
                if let google = page.google {
                    CalendarAccountControls(page: page, google: google, signIn: signIn)
                } else { Label("Demo calendar", systemImage: "calendar") }
            }
            // Small controls draw their text at 11 points; a larger font would cut it off.
            .font(.system(size: 11)).controlSize(.small).foregroundStyle(.secondary)
            Button { page.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Refresh events")
            Picker("Calendar view", selection: Binding(get: { page.mode }, set: { page.setMode($0) })) {
                ForEach(CalendarPage.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small).help("← and → switch views")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).frame(height: 46)
    }

    /// ‹ Today › in one quiet group.
    private var stepper: some View {
        HStack(spacing: 0) {
            Button { page.step(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .help("Previous (↑)").accessibilityLabel("Previous")
            Button { page.today() } label: { Text("Today").padding(.horizontal, 4).frame(height: 22).contentShape(Rectangle()) }
                .help("Go to today")
            Button { page.step(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .help("Next (↓)").accessibilityLabel("Next")
        }
        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var month: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(page.days.prefix(7), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.padding(.vertical, 7)
            Divider()
            let weeks = stride(from: 0, to: page.days.count, by: 7).map { Array(page.days[$0..<min($0 + 7, page.days.count)]) }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        monthDay(day)
                        if day != week.last { Divider() }
                    }
                }.frame(maxHeight: .infinity)
                if week.first != weeks.last?.first { Divider() }
            }
        }
    }

    private func monthDay(_ day: Date) -> some View {
        let events = page.events(on: day)
        let today = Calendar.current.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Spacer()
                Button(day.formatted(.dateTime.day())) { page.showDay(day) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: today ? .semibold : .medium)).monospacedDigit()
                    .foregroundStyle(today ? Color.white : .primary)
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(today ? Color.accentColor : .clear))
            }
            ForEach(events.prefix(3)) { event in
                CalendarEventButton(event: event, selected: page.selectedEvent?.id == event.id) { page.select(event) }.frame(height: 20)
            }
            if events.count > 3 {
                Button("+\(events.count - 3) more") { page.showDay(day) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).opacity(page.inMonth(day) ? 1 : 0.5)
    }

    private var googleList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if page.displayedEvents.isEmpty { Text(page.loading ? "Loading events…" : "No events in this week.").foregroundStyle(.secondary).padding() }
                ForEach(page.days, id: \.self) { day in
                    let events = page.events(on: day)
                    if !events.isEmpty {
                        Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.headline).padding(.top, 8)
                        ForEach(events) { event in
                            Button { page.select(event) } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4)
                                    Text(event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.title).fontWeight(.medium)
                                        Text([event.calendarName, event.location].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if event.meetingURL != nil { Image(systemName: "video") }
                                }.padding(10).background(RoundedRectangle(cornerRadius: 7).fill(event.color.opacity(page.selectedEvent?.id == event.id ? 0.22 : 0.08)))
                            }.buttonStyle(.plain).accessibilityAddTraits(page.selectedEvent?.id == event.id ? .isSelected : [])
                        }
                    }
                }
            }.padding(16)
        }
    }
}

private struct CalendarAccountControls: View {
    @ObservedObject var page: CalendarPage
    @ObservedObject var google: GoogleCalendarAccount
    let signIn: () -> Void
    @State private var error: String?
    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("On This Mac") { page.use(.mac) }
                if google.connected { Button(google.label) { page.use(.google) } }
                Button(google.connected ? "Sign in again…" : "Connect Google Calendar…", action: signIn)
                if google.connected {
                    Divider()
                    Button("Disconnect Google Calendar") {
                        do { try google.disconnect(); page.use(.mac) } catch { self.error = "Could not remove the Calendar token from the Keychain. Try again." }
                    }
                }
            } label: { Label(page.source == .google ? google.label : "On This Mac", systemImage: "calendar") }
                .fixedSize().menuStyle(.borderlessButton)
            if !google.connected { Button("Connect Google", action: signIn).controlSize(.small).fixedSize() }
            if page.source == .google, !google.calendars.isEmpty {
                Menu("Calendars") {
                    ForEach(google.calendars) { calendar in
                        Toggle(calendar.summary, isOn: Binding(get: { google.enabledIDs.contains(calendar.id) }, set: {
                            google.setEnabled(calendar.id, enabled: $0); page.refresh()
                        }))
                    }
                }.fixedSize().menuStyle(.borderlessButton)
            }
        }.alert("Google Calendar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct CalendarEventButton: View {
    /// `title` alone, for Month and all-day rows; `line` adds the start time after the title, for
    /// short events; `block` puts the time range under the title.
    enum Style { case title, line, block }
    let event: CalendarPage.Event
    var selected = false
    var style = Style.title
    var fillsHeight = false
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3)
                    .frame(maxHeight: style == .block ? .infinity : 14)
                content
                Spacer(minLength: 0)
                if event.meetingURL != nil && style != .title {
                    Image(systemName: "video.fill").font(.system(size: 8)).foregroundStyle(.secondary).padding(.top, 3)
                }
            }
            .padding(.leading, 3).padding(.trailing, 5).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(event.color.opacity(selected ? 0.34 : event.allDay ? 0.24 : 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(event.color.opacity(selected ? 0.85 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(event.title + " · " + when)
        .accessibilityLabel(event.title + ", " + when)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        let title = Text(event.title).font(.system(size: 11.5, weight: .semibold))
        switch style {
        case .title: title.lineLimit(1)
        case .line:
            // The time gives way when the title needs the room.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { title.lineLimit(1); time(start) }
                title.lineLimit(1)
            }
        case .block:
            VStack(alignment: .leading, spacing: 1) {
                title.lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    time(start + " – " + event.end.formatted(date: .omitted, time: .shortened))
                    time(start)
                }
            }
        }
    }

    private func time(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    private var start: String { event.start.formatted(date: .omitted, time: .shortened) }
    private var when: String { event.allDay ? "All day" : start }
}
