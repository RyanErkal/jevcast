import SwiftUI
import LauncherCore

/// One selectable row per conversation. Replies live in the reader, not nested list rows.
struct MailConversationSummaryRow: View {
    let conversation: MailConversation
    var isVIP = false
    var delete: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(conversation.hasUnread ? Color.accentColor : Color.clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.latest.summary.sender)
                    .font(.system(size: 13, weight: conversation.hasUnread ? .semibold : .regular)).lineLimit(1)
                Text(conversation.subject.isEmpty ? "No subject" : conversation.subject).font(.system(size: 12))
                    .foregroundStyle(conversation.hasUnread ? .primary : .secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if isVIP { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption).accessibilityLabel("VIP sender") }
            if conversation.messages.count > 1 { Text("\(conversation.messages.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if conversation.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
            if conversation.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
            if hovering {
                Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete (⌫)")
            } else {
                Text(MailRow.date(conversation.latest.summary.date)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3).contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(conversation.latest.summary.sender), \(conversation.subject), \(conversation.messages.count) messages")
    }
}

/// A single scrolling document displays each reply. Loading does not mark other replies read.
struct MailConversationReader: View {
    @ObservedObject var model: MailModel
    let conversation: MailConversation
    let zoom: Double
    let fitsWidth: Bool
    let prefersPlain: Bool
    @State private var entries: [MailThreadHTML.Entry] = []
    @State private var loading = true
    @State private var attempt = 0

    private var loadKey: String {
        conversation.stableID + ":" + conversation.messages.map { String($0.summary.rowID) }.joined(separator: ",") + ":\(attempt)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView().controlSize(.small).padding(6)
            }
            if !loading && entries.contains(where: { $0.body == nil }) {
                Button("Retry missing messages") { attempt += 1 }.buttonStyle(.link).font(.caption).padding(6)
            }
            MailHTMLView(html: MailThreadHTML.render(entries, prefersPlain: prefersPlain),
                         documentID: conversation.latest.summary.rowID, loadsRemote: model.loadsImages,
                         zoom: zoom, fitsWidth: fitsWidth, selectMessage: { id in
                guard conversation.messages.contains(where: { $0.summary.rowID == id }) else { return }
                model.select(id, byUser: true)
            })
        }
        .task(id: loadKey) {
            loading = true
            entries = []
            for item in conversation.messages {
                let body = await model.conversationBody(item.summary)
                guard !Task.isCancelled else { return }
                entries.append(.init(message: item.summary, body: body))
            }
            loading = false
        }
    }
}
