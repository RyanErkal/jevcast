import LauncherCore
import SwiftUI

struct CalendarPageView: View {
    @ObservedObject var page: CalendarPage
    let list: SourcePage

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let event = page.selectedEvent {
                CalendarEventDetail(event: event, back: page.clearSelection, open: page.open, openCalendar: { page.openInCalendar(event) })
            } else if let problem = page.problem {
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
            } else if page.mode == .list {
                if page.source == .mac { list.content() } else { googleList }
            } else if page.mode == .month { month }
            else { CalendarTimeGrid(page: page) }
        }
    }

    private func signIn() {
        page.signIn()
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                if page.mode == .list && page.source == .mac { Text("Upcoming").font(.system(size: 17, weight: .semibold)) }
                else {
                Button { page.step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Previous (↑)")
                Button { page.step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).help("Next (↓)")
                Text(page.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Button("Today") { page.today() }.controlSize(.small)
                }
                Spacer(minLength: 8)
                Picker("Calendar view", selection: Binding(get: { page.mode }, set: { page.setMode($0) })) {
                    ForEach(CalendarPage.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize().help("← and → switch views")
            }
            HStack(spacing: 10) {
                if let google = page.google {
                    CalendarAccountControls(page: page, google: google, signIn: signIn)
                } else { Label("Demo calendar", systemImage: "calendar").foregroundStyle(.secondary) }
                Spacer()
                if page.loading { ProgressView().controlSize(.mini); Text("Loading…").foregroundStyle(.secondary) }
                Text(TimeZone.current.identifier.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.secondary)
                Button { page.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh events")
            }.font(.system(size: 11))
        }.padding(.horizontal, 16).padding(.vertical, 10)
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
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Spacer()
                Button(day.formatted(.dateTime.day())) { page.showDay(day) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.2) : .clear))
            }
            ForEach(events.prefix(3)) { event in CalendarEventButton(event: event) { page.select(event) }.frame(height: 22) }
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
                                }.padding(10).background(RoundedRectangle(cornerRadius: 7).fill(event.color.opacity(0.08)))
                            }.buttonStyle(.plain)
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
            if !google.connected { Button("Connect Google", action: signIn).controlSize(.small) }
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
    let event: CalendarPage.Event
    var showsTime = false
    var fillsHeight = false
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).fontWeight(.medium).lineLimit(2)
                    if showsTime { Text(event.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if event.meetingURL != nil { Image(systemName: "video").font(.system(size: 9)) }
            }.padding(4).frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 4).fill(event.color.opacity(event.allDay ? 0.26 : 0.16)))
        }.buttonStyle(.plain).font(.system(size: 11)).help(event.title + " · " + (event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)))
            .accessibilityLabel(event.title + ", " + (event.allDay ? "all day" : event.start.formatted(date: .omitted, time: .shortened)))
    }
}
