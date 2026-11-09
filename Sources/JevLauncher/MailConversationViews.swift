import SwiftUI
import LauncherCore

/// One selectable row per conversation. Replies live in the reader, not nested list rows.
/// A small colored mark and the account's address, so a row in a list of several accounts shows where it is.
struct MailAccountMark: Equatable {
    let title: String
    let color: Color

    /// A steady color per account: the same account has the same color after every launch.
    static func color(for accountID: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red]
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in accountID.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// One conversation in the list: who, the subject, and the start of the text. It draws again only
/// when its conversation changes, so typing a reply does not redraw the list.
struct MailConversationSummaryRow: View, Equatable {
    let conversation: MailConversation
    var isVIP = false
    var account: MailAccountMark?
    var delete: () -> Void = {}
    @State private var hovering = false

    nonisolated static func == (lhs: MailConversationSummaryRow, rhs: MailConversationSummaryRow) -> Bool {
        lhs.conversation == rhs.conversation && lhs.isVIP == rhs.isVIP && lhs.account == rhs.account
    }

    var body: some View {
        let summary = conversation.latest.summary
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(conversation.hasUnread ? Color.accentColor : Color.clear).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(summary.sender)
                        .font(.system(size: 13, weight: conversation.hasUnread ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 6)
                    if isVIP { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption).accessibilityLabel("VIP sender") }
                    if conversation.messages.count > 1 { Text("\(conversation.messages.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    if conversation.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                    if conversation.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                    if hovering {
                        Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete (⌫)")
                    } else {
                        Text(MailRow.date(summary.date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(conversation.subject.isEmpty ? "No subject" : conversation.subject).font(.system(size: 12))
                    .foregroundStyle(conversation.hasUnread ? .primary : .secondary).lineLimit(1)
                let preview = Self.preview(summary.snippet)
                if !preview.isEmpty || account != nil {
                    HStack(spacing: 5) {
                        if let account {
                            Circle().fill(account.color).frame(width: 6, height: 6)
                                .help(account.title).accessibilityLabel("Account " + account.title)
                        }
                        Text(preview).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 3).contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(summary.sender), \(conversation.subject), \(conversation.messages.count) messages")
    }

    /// The start of the message as one line.
    static func preview(_ snippet: String) -> String {
        String(snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(140))
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
    /// The rendered document. It is built when a reply loads, not on every redraw of the pane.
    @State private var html = MailThreadHTML.style
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
            MailHTMLView(html: html,
                         documentID: conversation.latest.summary.rowID, loadsRemote: model.loadsImages,
                         zoom: zoom, fitsWidth: fitsWidth, selectMessage: { id in
                guard conversation.messages.contains(where: { $0.summary.rowID == id }) else { return }
                model.select(id, byUser: true)
            })
        }
        .task(id: loadKey) {
            loading = true
            entries = []
            html = MailThreadHTML.style
            for item in conversation.messages {
                let body = await model.conversationBody(item.summary)
                guard !Task.isCancelled else { return }
                entries.append(.init(message: item.summary, body: body))
                // The newest replies show while older ones still load.
                if entries.count <= MailThreadHTML.openReplies { html = MailThreadHTML.render(entries, prefersPlain: prefersPlain) }
            }
            html = MailThreadHTML.render(entries, prefersPlain: prefersPlain)
            loading = false
        }
        .onChange(of: prefersPlain) { _, plain in html = MailThreadHTML.render(entries, prefersPlain: plain) }
    }
}
