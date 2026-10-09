import Foundation
import LauncherCore

enum MailDraftImportResult: Equatable, Sendable {
    case imported(MailModel.Draft)
    case alreadyOpen(MailModel.Draft)
    /// Both values remain local: the caller's existing draft stays open and the remote value is
    /// retained in MailModel.unsent for explicit review.
    case conflict(local: MailModel.Draft, remote: MailModel.Draft)
}

struct MailDraftImportConflict: Identifiable, Equatable, Sendable {
    let local: MailModel.Draft
    let remote: MailModel.Draft
    let reason: String
    var id: UUID { remote.id }
}

enum MailDraftImportBuilder {
    static func build(raw: Data, message: MIMEMessage, reference: MailServerDraftReference,
                      identity: MailSendingIdentity, senders: [MailSendingIdentity]) -> MailModel.Draft {
        let plain = message.plainText ?? message.html.map(HTMLText.plain) ?? ""
        let files = MIMEMessage.files(raw).map {
            OutgoingMessage.Attachment(filename: $0.name, mimeType: $0.mimeType, data: $0.data)
        }
        let inline = message.inlineImages.sorted { $0.key < $1.key }.map {
            OutgoingMessage.Attachment(filename: "inline-image", mimeType: $0.value.mimeType,
                                       data: $0.value.data, contentID: $0.key)
        }
        var draft = MailModel.Draft()
        draft.backend = MailBackend.jevcast.rawValue
        draft.messageID = reference.messageID
        draft.fromAccountID = identity.accountID
        draft.fromAddress = identity.address
        draft.fromName = identity.name
        draft.fromIdentityID = identity.id
        draft.senderWasChosen = true
        draft.ownAddresses = senders.map { $0.address }
        draft.to = message.header("To") ?? ""
        draft.cc = message.header("Cc") ?? ""
        draft.bcc = message.header("Bcc") ?? ""
        draft.subject = message.header("Subject") ?? ""
        draft.body = plain
        draft.attachments = inline + files
        draft.serverDraftReference = reference
        draft.serverDraftInReplyTo = message.header("In-Reply-To")
        draft.serverDraftReferences = MailReplies.messageIDs(message.header("References") ?? "")
        draft.serverDraftHTML = message.html
        draft.serverDraftHTMLBody = plain
        draft.serverDraftImported = true
        return draft
    }
}
