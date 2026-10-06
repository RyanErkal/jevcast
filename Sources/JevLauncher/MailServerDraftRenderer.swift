import Foundation
import LauncherCore

enum MailServerDraftRenderError: Error, LocalizedError, Equatable {
    case senderMissing
    case forwardAttachmentsUnavailable

    var errorDescription: String? {
        switch self {
        case .senderMissing: return "Select a sending account before saving this server draft."
        case .forwardAttachmentsUnavailable:
            return "The original forward attachments are not available yet. Open the original message again before saving this draft."
        }
    }
}

/// Converts the local composer value into the raw message saved in Jevcast's server Drafts
/// mailbox. This is separate from `MailComposer.render`, whose sent-message contract excludes
/// Bcc.
enum MailServerDraftRenderer {
    static func render(_ draft: MailModel.Draft, sender: MailSendingIdentity?) throws -> Data {
        guard let address = draft.fromAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            throw MailServerDraftRenderError.senderMissing
        }

        let source = draft.source
        let original = draft.original
        var body = draft.body
        var html = draftHTML(draft)
        var attachments = draft.attachments
        var inReplyTo = draft.serverDraftInReplyTo
        var references = draft.serverDraftReferences ?? []

        switch draft.mode {
        case .new:
            break
        case .reply:
            if let source {
                let date = original?.date ?? Date()
                let senderText = original.map { $0.senderName.isEmpty ? $0.senderAddress : "\($0.senderName) <\($0.senderAddress)>" }
                    ?? source.message.header("From") ?? ""
                body = MailReplies.replyBody(draft.body, original: source.message, sender: senderText,
                                             date: date, quote: draft.includesQuote)
                html = html + (draft.includesQuote ? MailHTML.quoted(source.message,
                                                                       attribution: MailReplies.replyAttribution(date: date, sender: senderText)) : "")
                let threading = MailReplies.references(of: source.message)
                inReplyTo = threading.inReplyTo
                references = threading.references
                attachments += inlineAttachments(source.message)
            }
        case .forward:
            if let source {
                let date = original?.date ?? Date()
                body = MailReplies.forwardBody(draft.body, original: source.message, date: date)
                html += MailHTML.forwarded(source.message, date: MailReplies.attribution(date))
                attachments += inlineAttachments(source.message)
                if let captured = source.forwardAttachments {
                    attachments += captured
                } else if !source.message.attachments.isEmpty {
                    // Do not silently produce a forward that loses files. The next source
                    // capture will provide immutable bytes before this can be saved.
                    throw MailServerDraftRenderError.forwardAttachmentsUnavailable
                }
            }
        }

        // The editor's inline files are real attachments and need matching cid: references in
        // the HTML alternative. `MailRichText.html` already escaped all editor text.
        for image in draft.attachments where image.contentID != nil {
            html += "<p><img style=\"max-width:100%\" src=\"cid:" + MailHTML.escape(image.contentID ?? "")
                + "\" alt=\"" + MailHTML.escape(image.filename) + "\"></p>"
        }

        var message = OutgoingMessage(from: MailContact(name: sender?.name ?? "", address: address),
                                      to: contacts(draft.to), subject: draft.subject, body: body)
        message.cc = contacts(draft.cc)
        message.bcc = contacts(draft.bcc)
        message.html = html
        message.attachments = attachments
        message.inReplyTo = inReplyTo
        message.references = references
        message.messageID = draft.sendingMessageID
        return MailComposer.renderServerDraft(message, toHeader: draft.to, ccHeader: draft.cc, bccHeader: draft.bcc)
    }

    private static func draftHTML(_ draft: MailModel.Draft) -> String {
        if draft.richText == nil, draft.serverDraftHTMLBody == draft.body, let html = draft.serverDraftHTML {
            return MailHTML.clean(html)
        }
        return MailRichText.html(draft.richText, plain: draft.body)
    }

    private static func contacts(_ text: String) -> [MailContact] {
        (try? MailActions.contacts(text)) ?? []
    }

    private static func inlineAttachments(_ message: MIMEMessage) -> [OutgoingMessage.Attachment] {
        message.inlineImages.sorted { $0.key < $1.key }.map {
            .init(filename: "inline-image", mimeType: $0.value.mimeType, data: $0.value.data, contentID: $0.key)
        }
    }
}
