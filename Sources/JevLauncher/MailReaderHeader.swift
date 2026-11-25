import SwiftUI
import LauncherCore

/// The top of the reader, the same for one message and a conversation: the sender's initials,
/// who sent it, the subject, and a short date. It draws at once from the list's data. The
/// recipient line always takes its room, so the text below does not move when the body arrives.
/// In a conversation it shows the reply that the actions use.
struct MailReaderHeader: View {
    @ObservedObject var model: MailModel
    let message: MailSummary
    let detail: MIMEMessage?
    /// Shown as a link beside the sender when the message says how to leave its list.
    var unsubscribe: MailUnsubscribe?
    /// Replies in the conversation, when there are more than one.
    var replies = 1

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MailAvatar(name: message.senderName, address: message.senderAddress, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.sender).font(.system(size: MailStyle.sender, weight: .semibold)).lineLimit(1)
                        .layoutPriority(1)
                    if !message.senderName.isEmpty {
                        Text(message.senderAddress).font(.system(size: MailStyle.preview)).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let unsubscribe { MailUnsubscribeButton(model: model, unsubscribe: unsubscribe).fixedSize() }
                    Spacer(minLength: 8)
                    Text(MailDates.short(message.date)).font(.system(size: MailStyle.meta)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                        .help(MailDates.full(message.date))
                        .accessibilityLabel("Sent " + MailDates.full(message.date))
                }
                .textSelection(.enabled)
                Text(message.subject.isEmpty ? "No subject" : message.subject)
                    .font(.system(size: MailStyle.subjectTitle, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                Text(recipients ?? " ").font(.system(size: MailStyle.meta)).foregroundStyle(.secondary).lineLimit(1)
                    .help(recipients ?? "")
                    .accessibilityHidden(recipients == nil)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }

    /// "To: …" and "Cc: …" on one line, or a count of replies in a conversation.
    private var recipients: String? {
        var parts: [String] = []
        if let to = detail?.header("To") { parts.append("To: " + to) }
        if let cc = detail?.header("Cc") { parts.append("Cc: " + cc) }
        if replies > 1 { parts.insert("\(replies) messages", at: 0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
