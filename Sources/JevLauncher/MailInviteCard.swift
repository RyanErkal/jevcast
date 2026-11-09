import LauncherCore
import SwiftUI

/// The meeting invitation in a message: what, when, where, who asks, and your answer.
/// Accept, Maybe, and Decline send the answer to the organizer. Add to Calendar saves the event on this Mac.
struct MailInviteCard: View {
    @ObservedObject var model: MailModel
    let invite: CalendarInvite
    @State private var added = false
    @State private var problem: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: invite.method == .cancel ? "calendar.badge.minus" : "calendar")
                .font(.system(size: 20)).foregroundStyle(invite.method == .cancel ? Color.red : Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(invite.title.isEmpty ? "Invitation" : invite.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(when).font(.system(size: 12)).foregroundStyle(.secondary)
                if !invite.location.isEmpty { Text(invite.location).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                if let organizer = invite.organizer {
                    Text("From " + (organizer.name.isEmpty ? organizer.address : organizer.name)
                         + (invite.attendees.count > 1 ? " · \(invite.attendees.count) guests" : ""))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                status
                if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.red) }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onChange(of: invite.uid) { _, _ in added = false; problem = nil }
    }

    @ViewBuilder private var status: some View {
        if invite.method == .cancel {
            Text("This event was cancelled.").font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
        } else if invite.method == .reply, let person = invite.attendees.first {
            Text((person.name.isEmpty ? person.address : person.name) + ": " + Self.word(person.status))
                .font(.system(size: 12, weight: .medium))
        } else if let answer = model.inviteAnswer {
            Label("You answered: " + answer.verb, systemImage: answer == .declined ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(answer == .declined ? Color.red : Color.green)
        }
    }

    @ViewBuilder private var actions: some View {
        if invite.method == .request {
            VStack(alignment: .trailing, spacing: 6) {
                if model.canAnswerInvite {
                    HStack(spacing: 6) {
                        answer(.accepted, "Accept")
                        answer(.tentative, "Maybe")
                        answer(.declined, "Decline")
                    }
                    .disabled(model.inviteBusy)
                }
                Button(added ? "Added" : "Add to Calendar") { add() }.buttonStyle(.link).font(.system(size: 12)).disabled(added)
                    .help("Saves the event to a calendar on this Mac")
            }
        }
    }

    private func answer(_ response: CalendarInvite.Response, _ title: String) -> some View {
        let chosen = model.inviteAnswer == response
        return Group {
            if chosen { Button(title) { model.answerInvite(response) }.buttonStyle(.borderedProminent) }
            else { Button(title) { model.answerInvite(response) }.buttonStyle(.bordered) }
        }
        .controlSize(.small).help("Sends your answer to the organizer")
    }

    private var when: String {
        if invite.allDay {
            let last = invite.end.addingTimeInterval(-1)
            let first = invite.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
            return Calendar.current.isDate(invite.start, inSameDayAs: last) ? first + " · All day"
                : first + " to " + last.formatted(.dateTime.day().month(.abbreviated).year())
        }
        let day = invite.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        return day + " · " + invite.start.formatted(date: .omitted, time: .shortened) + " – " + invite.end.formatted(date: .omitted, time: .shortened)
            + (invite.recurring ? " · Repeats" : "")
    }

    private func add() {
        let writer = EventKitCalendarWriter()
        Task { @MainActor in
            guard await writer.allowed() else { problem = CalendarWriteError.noAccess.localizedDescription; return }
            let end = invite.allDay ? max(invite.start, invite.end.addingTimeInterval(-1)) : invite.end
            let draft = CalendarEventDraft(title: invite.title.isEmpty ? "Invitation" : invite.title, start: invite.start, end: end, allDay: invite.allDay,
                                           calendarID: writer.defaultCalendarID, location: invite.location, notes: invite.notes)
            do { try writer.save(draft, eventID: nil, occurrence: nil, future: false); added = true; problem = nil; CalendarPage.clearCache() }
            catch { problem = error.localizedDescription }
        }
    }

    static func word(_ status: String) -> String {
        switch status {
        case "ACCEPTED": return "Accepted"
        case "DECLINED": return "Declined"
        case "TENTATIVE": return "Maybe"
        default: return "No answer yet"
        }
    }
}

/// Leaves a mailing list: one click, then a confirmation that says exactly what happens.
struct MailUnsubscribeButton: View {
    @ObservedObject var model: MailModel
    let unsubscribe: MailUnsubscribe
    @State private var asking = false

    var body: some View {
        Button("Unsubscribe") { asking = true }
            .buttonStyle(.link).font(.caption).disabled(model.inviteBusy)
            .help("Leave this mailing list")
            .confirmationDialog("Unsubscribe from this list?", isPresented: $asking) {
                Button("Unsubscribe") { if let page = model.unsubscribeFromList() { Frontmost.open(page) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text(message) }
    }

    private var message: String {
        if NativeMailCenter.isActive, let to = unsubscribe.mail?.to.first {
            return "Jevcast sends the list's unsubscribe email to " + to + " from the account that received this message."
        }
        if let web = unsubscribe.web { return "The list's unsubscribe page opens in your browser: " + (web.host ?? "") }
        return "This list gives an email address only, and this account cannot send it."
    }
}
