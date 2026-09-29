import Foundation
import LauncherCore

extension MailModel {
    /// A reply, forward, or new message being written. Each draft has its own `id`, so a view, a
    /// late Quill result, or a failed send can tell one draft from the next.
    struct Draft: Equatable, Identifiable {
        enum Mode: Equatable { case new, reply(all: Bool), forward }
        let id = UUID()
        var mode: Mode = .new
        var to = ""
        var cc = ""
        var subject = ""
        var body = ""
        var instruction = ""
        /// The message a reply or forward answers.
        var original: MailSummary?
        /// The answered message's text and headers from when the draft started. The selection can
        /// move to another message later, so the composer, its To line, and Quill read this.
        var source: Source?

        struct Source: Equatable {
            let rowID: Int64
            let message: MIMEMessage
            let html: String?
            /// One row is one message, so the row decides, not a compare of the whole text.
            static func == (a: Source, b: Source) -> Bool { a.rowID == b.rowID }
        }

        /// The fields you type in, to see when the draft changed.
        var fields: [String] { [to, cc, subject, body, instruction] }

        /// True when you typed something. A reply's To and the Re: or Fwd: subject are filled in
        /// for you, so they do not count. A draft with content is never replaced or discarded at once.
        var hasContent: Bool {
            let typed: [String]
            switch mode {
            case .new: typed = [to, cc, subject, body, instruction]
            case .forward: typed = [to, body, instruction]
            case .reply: typed = [body, instruction]
            }
            return typed.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        /// "reply" or "message", for notes such as "Finish or discard your open reply first."
        var noun: String { if case .reply = mode { return "reply" }; return "message" }

        /// What stops sending, or nil when the draft can go. Send and ⌘Return both check it, so an
        /// empty reply never goes out. A forward may have no text; Mail sends the original.
        var sendProblem: String? {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            switch mode {
            case .reply: return text.isEmpty ? "Write your reply first." : nil
            case .forward: return Self.addressProblem(to, required: true)
            case .new:
                if let problem = Self.addressProblem(to, required: true) ?? Self.addressProblem(cc, required: false) { return problem }
                return text.isEmpty && subject.trimmingCharacters(in: .whitespaces).isEmpty ? "Write a subject or a message first." : nil
            }
        }
        var canSend: Bool { sendProblem == nil }

        /// Text such as "," has no address in it, so it counts as no recipient.
        private static func addressProblem(_ text: String, required: Bool) -> String? {
            do { return try MailActions.addresses(text).isEmpty && required ? "Add a recipient." : nil }
            catch { return error.localizedDescription }
        }

        /// Who a reply goes to, for the composer's To line. See `ReplyLine`.
        var replyLine: ReplyLine? {
            guard case .reply(let all) = mode, let original else { return nil }
            return ReplyLine(original: original, message: source?.message, all: all)
        }
    }

    /// A draft that did not go: a send failed or was undone while another draft was open.
    /// The banner offers Show until you take it back.
    struct Unsent: Identifiable, Equatable {
        let draft: Draft
        let reason: String
        var id: UUID { draft.id }
    }
}

/// Who a reply goes to, from the answered message's headers: its Reply-To or sender, and for Reply
/// All everyone else on To and Cc. Apple Mail picks the final list itself when it sends, so this
/// is what it will most likely use, not a promise.
struct ReplyLine: Equatable {
    /// The Reply-To addresses, or the sender.
    let primary: [MailContact]
    /// Reply All: the others on To and Cc, without the primary and your address.
    let others: [MailContact]
    /// Addresses that came from Reply-To and differ from the sender.
    let replyTo: Set<String>
    /// False when the headers were not read yet, so Reply All cannot list who else gets it.
    let known: Bool
    let all: Bool

    init(original: MailSummary, message: MIMEMessage?, all: Bool) {
        self.all = all
        let sender = MailContact(name: original.senderName, address: original.senderAddress)
        guard let message else {
            primary = [sender]; others = []; replyTo = []; known = false
            return
        }
        func contacts(_ header: String) -> [MailContact] {
            MailAddress.list(message.header(header) ?? "").map { MailContact(name: $0.name, address: $0.address) }.filter { !$0.address.isEmpty }
        }
        // The address the message was delivered to is yours; Apple Mail leaves your addresses out.
        let own = Set((contacts("Delivered-To") + contacts("X-Original-To")).map(\.address))
        let (to, cc) = MailReplies.recipients(of: message, all: all, own: own)
        primary = to.isEmpty ? [sender] : to
        others = cc
        let from = Set(contacts("From").map { $0.address.lowercased() })
        replyTo = Set(contacts("Reply-To").map { $0.address.lowercased() }.filter { !from.contains($0) })
        known = true
    }

    /// The short line: "Sam Lee <sam@example.com>", or for Reply All
    /// "Sam, and 5 others: Ann, Bob, Carl, Dee, Eve". "(Reply-To)" marks a Reply-To address.
    var text: String {
        if !all, primary.count == 1, let only = primary.first { return full(only) }
        let lead = primary.map(short).joined(separator: ", ")
        guard all else { return lead }
        guard known else { return lead + ", and everyone else on the message" }
        guard !others.isEmpty else { return lead }
        return lead + ", and \(others.count) other\(others.count == 1 ? "" : "s"): " + others.map(short).joined(separator: ", ")
    }

    /// Every address on its own line, for the tooltip.
    var detail: String {
        let lines = (primary + others).map(full)
        return (lines + (known || !all ? [] : ["Everyone else on the message"])).joined(separator: "\n")
    }

    private func marked(_ contact: MailContact) -> String { replyTo.contains(contact.address.lowercased()) ? " (Reply-To)" : "" }
    private func short(_ contact: MailContact) -> String { (contact.name.isEmpty ? contact.address : contact.name) + marked(contact) }
    private func full(_ contact: MailContact) -> String {
        (contact.name.isEmpty ? contact.address : "\(contact.name) <\(contact.address)>") + marked(contact)
    }
}
