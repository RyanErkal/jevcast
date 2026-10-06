import Foundation
import LauncherCore

extension MailModel {
    /// A reply, forward, or new message being written. Each draft has its own `id`, so a view, a
    /// late AI writing result, or a failed send can tell one draft from the next.
    struct Draft: Codable, Equatable, Identifiable, Sendable {
        enum Mode: Codable, Equatable, Sendable { case new, reply(all: Bool), forward }
        var id = UUID()
        var backend = MailBackend.current.rawValue
        var messageID = "<\(UUID().uuidString.lowercased())@jevcast.local>"
        var fromAccountID: String?
        var fromAddress: String?
        var senderWasChosen = false
        var ownAddresses: [String] = []
        var richText: Data?
        var attachments: [OutgoingMessage.Attachment] = []
        var uncertainSend = false
        /// The exact server Drafts message owned by this local draft, when one exists.
        /// Optional so older composition snapshots still decode.
        var serverDraftReference: MailServerDraftReference?
        /// When a replacement appended successfully but could not remove the previous UID, both
        /// references remain here for explicit recovery. Never retry this automatically.
        var previousServerDraftReference: MailServerDraftReference?
        /// A local checkpoint or server acknowledgement problem that blocks another mutation.
        var serverDraftBlockedReason: String?
        /// True when APPEND or removal could not be acknowledged safely.
        var serverDraftAcknowledgementUncertain: Bool?
        /// Threading and raw HTML retained while editing a cross-device server draft.
        var serverDraftInReplyTo: String?
        var serverDraftReferences: [String]?
        var serverDraftHTML: String?
        var serverDraftHTMLBody: String?
        var mode: Mode = .new
        var to = ""
        var cc = ""
        /// Optional so drafts saved by an older build still load. Use `bcc`.
        var bccText: String?
        var subject = ""
        var body = ""
        var instruction = ""
        /// The message a reply or forward answers.
        var original: MailSummary?
        /// The answered message's text and headers from when the draft started. The selection can
        /// move to another message later, so the composer, its To line, and AI writing read this.
        var source: Source?
        /// True when the reply leaves out the original. Optional for older drafts. Use `includesQuote`.
        var quoteLeftOut: Bool?
        /// The To and Cc that `fillRecipients` wrote, so it refills them only until you edit them.
        var filledRecipients: [String]?

        var bcc: String { get { bccText ?? "" } set { bccText = newValue.isEmpty ? nil : newValue } }
        var includesQuote: Bool { get { quoteLeftOut != true } set { quoteLeftOut = newValue ? nil : true } }

        /// A reply goes to the original's Reply-To or sender, and Reply All also to the others on
        /// To and Cc, without your addresses. Fills To and Cc until you change them.
        mutating func fillRecipients() {
            guard case .reply = mode, let line = replyLine else { return }
            if let filled = filledRecipients, filled != [to, cc] { return }
            to = ReplyLine.field(line.primary)
            cc = ReplyLine.field(line.others)
            filledRecipients = [to, cc]
        }

        /// The Message-ID with the sending address's domain, as other mail programs write it. The
        /// random part stays, so a resend of the same draft keeps the same ID.
        var sendingMessageID: String {
            guard messageID.hasSuffix("@jevcast.local>"), let domain = fromAddress?.split(separator: "@").last, !domain.isEmpty else { return messageID }
            return String(messageID.dropLast("@jevcast.local>".count)) + "@" + domain + ">"
        }

        struct Source: Codable, Equatable, Sendable {
            let rowID: Int64
            let message: MIMEMessage
            let html: String?
            /// Immutable attachments captured from the original message for a forward. A nil
            /// value means the source was captured by an older build or without raw bytes.
            let forwardAttachments: [OutgoingMessage.Attachment]?
            /// One row is one message, so the row decides, not a compare of the whole text.
            static func == (a: Source, b: Source) -> Bool { a.rowID == b.rowID }

            init(rowID: Int64, message: MIMEMessage, html: String?,
                 forwardAttachments: [OutgoingMessage.Attachment]? = nil) {
                self.rowID = rowID
                self.message = message
                self.html = html
                self.forwardAttachments = forwardAttachments
            }
        }

        /// The render-affecting fields used by server-draft autosave ordering.
        ///
        /// Keep the values typed by the user as values. In particular, do not turn RTF or
        /// attachment bytes into a string on every MainActor edit. Equality on `Data` and the
        /// attachment value compares the bytes, so replacing a same-sized file still admits a
        /// server save.
        struct Fields: Equatable, Sendable {
            struct Source: Equatable, Sendable {
                let rowID: Int64
                let message: MIMEMessage
                let html: String?
                let forwardAttachments: [OutgoingMessage.Attachment]?

                static func == (lhs: Source, rhs: Source) -> Bool {
                    lhs.rowID == rhs.rowID
                        && lhs.message == rhs.message
                        && lhs.message.inlineImages == rhs.message.inlineImages
                        && lhs.html == rhs.html
                        && lhs.forwardAttachments == rhs.forwardAttachments
                }
            }

            let backend: String
            let messageID: String
            let fromAccountID: String?
            let fromAddress: String?
            let senderWasChosen: Bool
            let mode: Mode
            let to: String
            let cc: String
            let bcc: String
            let subject: String
            let body: String
            let instruction: String
            let richText: Data?
            let attachments: [OutgoingMessage.Attachment]
            let includesQuote: Bool
            let originalDate: Date?
            let originalSenderName: String?
            let originalSenderAddress: String?
            let source: Source?
            let serverDraftInReplyTo: String?
            let serverDraftReferences: [String]?
            let serverDraftHTML: String?
            let serverDraftHTMLBody: String?

            init(_ draft: Draft) {
                backend = draft.backend
                messageID = draft.messageID
                fromAccountID = draft.fromAccountID
                fromAddress = draft.fromAddress
                senderWasChosen = draft.senderWasChosen
                mode = draft.mode
                to = draft.to
                cc = draft.cc
                bcc = draft.bcc
                subject = draft.subject
                body = draft.body
                instruction = draft.instruction
                richText = draft.richText
                attachments = draft.attachments
                includesQuote = draft.includesQuote
                originalDate = draft.original?.date
                originalSenderName = draft.original?.senderName
                originalSenderAddress = draft.original?.senderAddress
                if let source = draft.source {
                    self.source = Source(rowID: source.rowID, message: source.message, html: source.html,
                                        forwardAttachments: source.forwardAttachments)
                } else {
                    source = nil
                }
                serverDraftInReplyTo = draft.serverDraftInReplyTo
                serverDraftReferences = draft.serverDraftReferences
                serverDraftHTML = draft.serverDraftHTML
                serverDraftHTMLBody = draft.serverDraftHTMLBody
            }
        }

        var fields: Fields { Fields(self) }

        /// True when you typed something. A reply's To and the Re: or Fwd: subject are filled in
        /// for you, so they do not count. A draft with content is never replaced or discarded at once.
        var hasContent: Bool {
            let typed: [String]
            switch mode {
            case .new: typed = [to, cc, bcc, subject, body, instruction]
            case .forward: typed = [to, cc, bcc, body, instruction]
            case .reply: typed = [body, instruction]
            }
            return serverDraftReference != nil || previousServerDraftReference != nil
                || !attachments.isEmpty || typed.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        /// "reply" or "message", for notes such as "Finish or discard your open reply first."
        var noun: String { if case .reply = mode { return "reply" }; return "message" }

        /// What stops sending, or nil when the draft can go. Send and ⌘Return both check it, so an
        /// empty reply never goes out. A forward may have no text; Mail sends the original.
        var sendProblem: String? {
            if uncertainSend { return "This message may already be sent. Check Sent, then use Allow Resend in Outbox if it was not sent." }
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // Apple Mail picks a reply's recipients itself; Jevcast's own accounts send to the fields.
            let checksTo = mode != .reply(all: false) && mode != .reply(all: true) || backend == MailBackend.jevcast.rawValue
            if checksTo, let problem = Self.addressProblem(to, required: true) ?? Self.addressProblem(cc, required: false) ?? Self.addressProblem(bcc, required: false) {
                return problem
            }
            if backend == MailBackend.jevcast.rawValue {
                let addresses = (try? MailActions.addresses(to + "," + cc + "," + bcc)) ?? []
                if addresses.contains(where: { !SMTPClient.isSafeAddress($0) }) {
                    return "Use standard email addresses. This mail server does not support non-ASCII addresses."
                }
            }
            switch mode {
            case .reply: return text.isEmpty ? "Write your reply first." : nil
            case .forward: return nil
            case .new:
                return text.isEmpty && subject.trimmingCharacters(in: .whitespaces).isEmpty && attachments.isEmpty ? "Write a subject or a message first." : nil
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
            return ReplyLine(original: original, message: source?.message, all: all, ownAddresses: ownAddresses)
        }
    }

    /// A draft that did not go: a send failed or was undone while another draft was open.
    /// The banner offers Show until you take it back.
    struct Unsent: Codable, Identifiable, Equatable, Sendable {
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

    init(original: MailSummary, message: MIMEMessage?, all: Bool, ownAddresses: [String] = []) {
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
        let own = Set((contacts("Delivered-To") + contacts("X-Original-To")).map(\.address) + ownAddresses)
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

    /// Addresses for a To or Cc field: "Sam Lee <sam@example.com>, ann@example.com". A name with
    /// a comma, semicolon, or quote is quoted, so the field reads back as the same people.
    static func field(_ contacts: [MailContact]) -> String {
        contacts.map { contact in
            guard !contact.name.isEmpty, contact.name.lowercased() != contact.address.lowercased() else { return contact.address }
            let name = contact.name.rangeOfCharacter(from: CharacterSet(charactersIn: ",;\"<>@")) == nil
                ? contact.name : "\"" + contact.name.replacingOccurrences(of: "\"", with: "'") + "\""
            return name + " <" + contact.address + ">"
        }.joined(separator: ", ")
    }

    private func marked(_ contact: MailContact) -> String { replyTo.contains(contact.address.lowercased()) ? " (Reply-To)" : "" }
    private func short(_ contact: MailContact) -> String { (contact.name.isEmpty ? contact.address : contact.name) + marked(contact) }
    private func full(_ contact: MailContact) -> String {
        (contact.name.isEmpty ? contact.address : "\(contact.name) <\(contact.address)>") + marked(contact)
    }
}
