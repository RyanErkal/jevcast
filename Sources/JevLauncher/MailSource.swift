import AppKit
import LauncherCore

/// "mail", "inbox", and "mail <words>" in the launcher: open the mail window, see unread
/// messages, or search. Rows open the message in the Jevcast mail window.
@MainActor
final class MailSource: ThingSource {
    let section = "Mail"
    private weak var model: LauncherModel?
    init(model: LauncherModel) { self.model = model }

    func load(_ filter: String) async throws -> [LauncherResult] {
        let open = Verb(title: "Open Mail") { [weak model] in model?.openMail?(nil); return nil }
        let compose = Verb(title: "New Message") { [weak model] in model?.composeMail?(""); return nil }
        guard case .ready(let root) = MailStore.status() else {
            return [LauncherResult(id: "mail:open", title: "Open Mail", detail: "Needs Full Disk Access to read Apple Mail", symbol: "envelope",
                                   action: .thing(Thing(verbs: [open, compose], twoLine: false)), score: 3100)]
        }
        let (boxes, messages) = try await Task.detached(priority: .userInitiated) { () throws -> ([MailMailbox], [MailSummary]) in
            let boxes = try MailStore.mailboxes(root: root)
            let inboxes = boxes.filter { $0.role == .inbox }.map(\.rowID)
            let query = filter.isEmpty ? MailStore.Query(mailboxes: inboxes, unreadOnly: true, limit: 6)
                                       : MailStore.Query(mailboxes: [], text: filter, limit: 15)
            return (boxes, try MailStore.messages(root: root, query))
        }.value
        let unread = boxes.filter { $0.role == .inbox }.map(\.unread).reduce(0, +)
        var rows = [LauncherResult(id: "mail:open", title: "Open Mail", detail: unread == 0 ? "Inbox" : "\(unread) unread in Inbox",
                                   symbol: "envelope", action: .thing(Thing(verbs: [open, compose], twoLine: false)), score: 3100)]
        rows += messages.enumerated().map { index, message in row(message, mailbox: boxes.first { $0.rowID == message.mailbox }, score: 3000 - Double(index)) }
        return rows
    }

    private func row(_ message: MailSummary, mailbox: MailMailbox?, score: Double) -> LauncherResult {
        var verbs = [Verb(title: "Open Message") { [weak model] in model?.openMail?(message.rowID); return nil }]
        if let mailbox {
            if !message.read {
                verbs.append(Verb(title: "Mark as Read", after: .stay) { try await MailActions.setRead(true, message, in: mailbox); return "Marked as read." })
            }
            verbs.append(Verb(title: message.flagged ? "Unflag" : "Flag", after: .stay) {
                try await MailActions.setFlagged(!message.flagged, message, in: mailbox); return message.flagged ? "Unflagged." : "Flagged."
            })
        }
        let detail = [message.sender, MailRow.date(message.date), message.snippet].filter { !$0.isEmpty }.joined(separator: " · ")
        return LauncherResult(id: "mail:\(message.rowID)", title: message.subject.isEmpty ? "No subject" : message.subject, detail: detail,
                              symbol: message.read ? "envelope.open" : "envelope.badge", action: .thing(Thing(verbs: verbs)), score: score)
    }
}
