import SwiftUI
import LauncherCore

/// The account a row belongs to, in a list that holds mail of several accounts: the account's own
/// colour, with its address in the tooltip.
struct MailAccountMark: Equatable {
    let title: String
    let color: Color

    /// The dot's width in a row, a little smaller than the unread dot.
    static let size: CGFloat = 6

    /// A steady color per account: the same account has the same color after every launch.
    static func color(for accountID: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red]
        return palette[paletteIndex(for: accountID)]
    }

    /// The place in the ten-colour palette for a key. The reader's conversation document uses it too.
    static func paletteIndex(for key: String) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % 10)
    }
}

/// How a row is selected. The list draws one wash per selected row: accent for the message on
/// screen, a quieter accent for the other rows of a selection.
enum MailRowHighlight: Equatable {
    case none, focused, member
}

/// One conversation in the list: who, the subject, and the start of the text. It draws again only
/// when its conversation, its selection, or its actions change, so typing a reply does not redraw
/// the list. The pointer's place is the row's own state, so hovering redraws one row.
struct MailConversationSummaryRow: View, Equatable {
    let conversation: MailConversation
    var isVIP = false
    /// The account's colour, as a small dot at the end of the subject line, in a list of several accounts.
    var account: MailAccountMark?
    /// The search words, marked where they occur.
    var highlight = ""
    var selection = MailRowHighlight.none
    /// The buttons under the pointer, such as Archive, Delete, and Read.
    var hoverActions: [MailRowAction] = []
    var act: (MailRowAction) -> Void = { _ in }
    /// The day the row's date is shown for, such as "13:14" today and "Yesterday" after midnight.
    var day = Calendar.current.startOfDay(for: Date())
    @State private var hovering = false
    @Environment(\.mailRowHoverPreview) private var hoverPreview

    nonisolated static func == (lhs: MailConversationSummaryRow, rhs: MailConversationSummaryRow) -> Bool {
        lhs.conversation == rhs.conversation && lhs.isVIP == rhs.isVIP && lhs.account == rhs.account && lhs.highlight == rhs.highlight
            && lhs.selection == rhs.selection && lhs.hoverActions == rhs.hoverActions && lhs.day == rhs.day
    }

    var body: some View {
        let summary = conversation.latest.summary
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(conversation.hasUnread ? Color.accentColor : Color.clear).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(marked(summary.sender))
                        .font(.system(size: MailStyle.sender, weight: conversation.hasUnread ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 6)
                    if isVIP { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                    if conversation.messages.count > 1 {
                        Text("\(conversation.messages.count)").font(.system(size: MailStyle.meta, weight: .medium)).monospacedDigit()
                            .foregroundStyle(quiet(.secondary)).padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    if conversation.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(quiet(.secondary)) }
                    if conversation.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                    // The date keeps its place: the buttons under the pointer lie over it.
                    Text(MailRow.date(summary.date)).font(.system(size: MailStyle.meta)).foregroundStyle(quiet(.secondary))
                }
                .overlay(alignment: .trailing) {
                    if (hovering || hoverPreview == summary.rowID), !hoverActions.isEmpty {
                        MailRowHoverBar(actions: hoverActions, unread: !summary.read, selection: selection, act: act)
                    }
                }
                HStack(spacing: 6) {
                    Text(marked(conversation.subject.isEmpty ? "No subject" : conversation.subject)).font(.system(size: MailStyle.subject))
                        .foregroundStyle(conversation.hasUnread ? AnyShapeStyle(.primary) : quiet(MailListWash.readSubject)).lineLimit(1)
                    // Under the date, away from the unread dot: the leading edge has one mark only.
                    if let account {
                        Spacer(minLength: 6)
                        Circle().fill(account.color).frame(width: MailAccountMark.size, height: MailAccountMark.size)
                            .help(account.title)
                    }
                }
                let preview = Self.preview(summary.snippet)
                if !preview.isEmpty {
                    Text(marked(preview)).font(.system(size: MailStyle.preview))
                        .foregroundStyle(quiet(conversation.hasUnread ? MailListWash.unreadPreview : MailListWash.readPreview)).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            ForEach(hoverActions, id: \.self) { action in
                Button(action.hoverTitle(unread: !summary.read)) { act(action) }
            }
        }
    }

    private var accessibilityText: String {
        let summary = conversation.latest.summary
        return Self.spokenLabel(sender: summary.sender, subject: conversation.subject, count: conversation.messages.count,
                                date: MailDates.full(summary.date), unread: conversation.hasUnread, flagged: conversation.isFlagged,
                                attachments: conversation.hasAttachments, vip: isVIP, account: account?.title)
    }

    /// What a screen reader says for a row: everything the row shows, as words. The account is
    /// named only when the row shows its colour.
    static func spokenLabel(sender: String, subject: String, count: Int, date: String, unread: Bool, flagged: Bool,
                            attachments: Bool, vip: Bool = false, account: String? = nil) -> String {
        var parts: [String] = []
        if unread { parts.append("Unread") }
        parts.append(sender)
        if vip { parts.append("VIP") }
        parts.append(subject.isEmpty ? "No subject" : subject)
        if count > 1 { parts.append("\(count) messages") }
        parts.append(date)
        if flagged { parts.append("Flagged") }
        if attachments { parts.append("Has attachments") }
        if let account { parts.append("Account " + account) }
        return parts.joined(separator: ", ")
    }

    /// Quiet text on an unselected row; text that reads on the wash on a selected one.
    private func quiet(_ style: HierarchicalShapeStyle) -> AnyShapeStyle { MailListWash.text(selection, quiet: style) }
    private func quiet(_ opacity: Double) -> AnyShapeStyle { MailListWash.text(selection, opacity: opacity) }

    private func marked(_ text: String) -> AttributedString {
        highlight.isEmpty ? AttributedString(text) : MailStyle.highlighted(text, words: highlight)
    }

    /// The start of the message as one line.
    static func preview(_ snippet: String) -> String {
        String(snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(140))
    }
}
