import LauncherCore
import SwiftUI

struct CalendarEventDetail: View {
    let event: CalendarPage.Event
    let back: () -> Void
    let open: (URL) -> Void
    let openCalendar: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: back) { Label("Back to calendar", systemImage: "chevron.left") }.buttonStyle(.borderless)
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 4).fill(event.color).frame(width: 7)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.title).font(.system(size: 26, weight: .semibold)).textSelection(.enabled)
                        Text(when).font(.callout).foregroundStyle(.secondary)
                        if let zone = event.timeZone, zone != TimeZone.current.identifier {
                            Text("Event time zone: " + zone + ". Times above use " + TimeZone.current.identifier + ".").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if let meeting = event.meetingURL {
                        Button { open(meeting) } label: { Label(meeting.host == "meet.google.com" ? "Join Google Meet" : "Join call", systemImage: "video.fill") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(event.localID == nil ? "Open in Google Calendar" : "Open in Calendar", action: openCalendar).buttonStyle(.bordered)
                }
                if !event.location.isEmpty { info("Location", symbol: "mappin.and.ellipse", text: event.location) }
                if !event.calendarName.isEmpty { info("Calendar", symbol: "calendar", text: event.calendarName) }
                if !event.organizer.isEmpty { info("Organizer", symbol: "person", text: event.organizer) }
                if !event.guests.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Guests (\(event.guests.count))", systemImage: "person.2").font(.headline)
                        ForEach(Array(event.guests.enumerated()), id: \.offset) { _, guest in
                            HStack { Text(guest.name).textSelection(.enabled); Spacer(); Text(response(guest.response)).foregroundStyle(.secondary) }.font(.callout)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("Description and meeting notes", systemImage: "text.alignleft").font(.headline)
                    Text(event.notes.isEmpty ? "This event has no description or meeting notes." : event.notes)
                        .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(event.notes.isEmpty ? .secondary : .primary)
                }
                if !event.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Links and attachments", systemImage: "paperclip").font(.headline)
                        ForEach(Array(event.attachments.enumerated()), id: \.offset) { _, item in
                            Button { open(item.url) } label: { Label(item.title, systemImage: "arrow.up.right.square") }.buttonStyle(.borderless)
                        }
                    }
                }
                if let meeting = event.meetingURL { Text(meeting.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.frame(maxWidth: 720, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var when: String {
        let start = event.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        if event.allDay {
            let final = event.end.addingTimeInterval(-1)
            if Calendar.current.isDate(event.start, inSameDayAs: final) { return start + " · All day" }
            return start + " to " + final.formatted(.dateTime.day().month(.wide).year()) + " · All day"
        }
        let sameDay = Calendar.current.isDate(event.start, inSameDayAs: event.end)
        return start + " · " + event.start.formatted(date: .omitted, time: .shortened) + " to "
            + (sameDay ? event.end.formatted(date: .omitted, time: .shortened) : event.end.formatted(date: .abbreviated, time: .shortened))
    }
    private func info(_ title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Label(title, systemImage: symbol).font(.headline); Text(text).font(.callout).textSelection(.enabled) }
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
