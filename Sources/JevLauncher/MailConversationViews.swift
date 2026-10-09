import SwiftUI
import LauncherCore

/// Compact conversation header used in the list. It expands in place, inside the launcher panel.
struct MailConversationSummaryRow: View {
    let conversation: MailConversation
    let expanded: Bool
    var isVIP = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.latest.summary.sender).font(.system(size: 13, weight: conversation.hasUnread ? .semibold : .regular)).lineLimit(1)
                    Text(conversation.subject.isEmpty ? "No subject" : conversation.subject).font(.system(size: 12))
                        .foregroundStyle(conversation.hasUnread ? .primary : .secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if isVIP { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption).accessibilityLabel("VIP sender") }
                if conversation.unreadCount > 0 { Text("\(conversation.unreadCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if conversation.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                if conversation.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                Text(MailRow.date(conversation.latest.summary.date)).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .accessibilityLabel("Conversation, \(conversation.subject.isEmpty ? "No subject" : conversation.subject), \(conversation.messages.count) messages")
    }
}

/// A thread strip in the reader. It selects one message without leaving the reader pane.
struct MailConversationReader: View {
    @ObservedObject var model: MailModel
    let conversation: MailConversation

    var body: some View {
        if conversation.messages.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Conversation · \(conversation.messages.count) messages").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(conversation.messages.reversed(), id: \.summary.rowID) { item in
                            Button {
                                model.select(item.summary.rowID, byUser: true)
                            } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(item.summary.read ? Color.clear : Color.accentColor).frame(width: 5, height: 5)
                                    Text(item.summary.sender).lineLimit(1)
                                    Text(MailRow.date(item.summary.date)).foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.quaternary.opacity(0.35))
        }
    }
}
