import LauncherCore
import SwiftUI

/// The selected event beside the calendar: when it is, the call, and its details. × or Escape closes it.
struct CalendarEventDetail: View {
    let event: CalendarPage.Event
    let close: () -> Void
    let open: (URL) -> Void
    let openCalendar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(event.color).frame(width: 8, height: 8)
                Text(event.calendarName.isEmpty ? "Event" : event.calendarName)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close (esc)").accessibilityLabel("Close event details")
            }
            .padding(.leading, 16).padding(.trailing, 10).frame(height: 40)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day)
                            Text(time).monospacedDigit()
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        if let zone = event.timeZone, zone != TimeZone.current.identifier {
                            Text("Event time zone: " + zone + ". Times above use " + TimeZone.current.identifier + ".")
                                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    actions
                    if !event.location.isEmpty || !event.organizer.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            if !event.location.isEmpty { fact("mappin.and.ellipse", event.location) }
                            if !event.organizer.isEmpty { fact("person", event.organizer, note: "Organizer") }
                        }
                    }
                    if !event.guests.isEmpty {
                        section("Guests · \(event.guests.count)") {
                            ForEach(Array(event.guests.enumerated()), id: \.offset) { _, guest in
                                HStack(spacing: 8) {
                                    Text(guest.name).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Spacer(minLength: 4)
                                    Text(response(guest.response)).foregroundStyle(.secondary)
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                    section("Notes") {
                        Text(event.notes.isEmpty ? "No description or meeting notes." : event.notes)
                            .font(.system(size: 12)).textSelection(.enabled)
                            .foregroundStyle(event.notes.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    if !event.attachments.isEmpty {
                        section("Links") {
                            ForEach(Array(event.attachments.enumerated()), id: \.offset) { _, item in
                                Button { open(item.url) } label: { Label(item.title, systemImage: "arrow.up.right.square") }
                                    .buttonStyle(.borderless).font(.system(size: 12))
                            }
                        }
                    }
                    if let meeting = event.meetingURL {
                        Text(meeting.absoluteString).font(.system(size: 11)).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if let meeting = event.meetingURL {
                Button { open(meeting) } label: {
                    Label(meeting.host == "meet.google.com" ? "Join Google Meet" : "Join Call", systemImage: "video.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            Button(action: openCalendar) {
                Text(event.localID == nil ? "Open in Google Calendar" : "Open in Calendar").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(event.meetingURL == nil ? .large : .regular)
        }
    }

    private var day: String {
        let start = event.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        guard event.allDay else {
            return start
        }
        let final = event.end.addingTimeInterval(-1)
        if Calendar.current.isDate(event.start, inSameDayAs: final) { return start }
        return start + " to " + final.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private var time: String {
        if event.allDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        guard Calendar.current.isDate(event.start, inSameDayAs: event.end) else {
            return start + " to " + event.end.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return start + " – " + event.end.formatted(date: .omitted, time: .shortened) + " · " + length
    }

    private var length: String {
        let minutes = max(0, Int(event.end.timeIntervalSince(event.start) / 60))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func fact(_ symbol: String, _ text: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 14)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let note { Text(note).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 12))
    }

    private func response(_ value: String) -> String {
        switch value {
        case "accepted": return "Accepted"
        case "declined": return "Declined"
        case "tentative": return "Maybe"
        case "needsAction", "pending": return "Awaiting response"
        default: return "Invited"
        }
    }
}
