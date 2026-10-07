import Foundation
import LauncherCore

extension MailModel {
    /// The first visible holder of a local draft's server state. The same ID can also be present
    /// in a delivery record while a send result is being filed.
    func serverDraft(for id: UUID) -> Draft? {
        if let draft, draft.id == id { return draft }
        if let pendingSend, pendingSend.id == id { return pendingSend }
        if let item = unsent.first(where: { $0.id == id }) { return item.draft }
        return deliveries.first(where: { $0.id == id })?.draft
    }

    /// A short status for a banner or row. It is local state only and never implies that a server
    /// operation completed successfully.
    var serverDraftStatus: String? {
        let holders = ([draft, pendingSend].compactMap { $0 } + unsent.map { $0.draft } + deliveries.compactMap { $0.draft })
        guard let value = holders.first(where: { $0.serverDraftBlockedReason != nil || $0.serverDraftAcknowledgementUncertain == true }) else { return nil }
        if let reason = value.serverDraftBlockedReason, !reason.isEmpty { return reason }
        return "The server draft needs review before Jevcast changes it again."
    }

    var serverDraftIsBlocked: Bool { serverDraftStatus != nil }

    /// The accepted-delivery cleanup pointer is persisted even when `recordDelivery` has removed
    /// the message body. The coordinator clears exact entries only after each removal succeeds.
    func serverDraftCleanupReferences(for id: UUID) -> [MailServerDraftReference] {
        deliveries.first(where: { $0.id == id })?.serverDraftCleanupReferences ?? []
    }

    @discardableResult
    func updateServerDraftCleanupReferences(for id: UUID, references: [MailServerDraftReference]) -> Bool {
        guard let index = deliveries.firstIndex(where: { $0.id == id }) else { return false }
        deliveries[index].serverDraftCleanupReferences = references.isEmpty ? nil : references
        return true
    }

    /// Updates every local holder for an ID. This is deliberately ID-based so a late server result
    /// cannot overwrite a different draft that now occupies the composer.
    @discardableResult
    func updateServerDraftState(for id: UUID, reference: MailServerDraftReference?,
                                previous: MailServerDraftReference? = nil,
                                blockedReason: String? = nil,
                                blockKind: Draft.ServerDraftBlockKind? = nil,
                                acknowledgementUncertain: Bool = false) -> Bool {
        let blockKind = blockedReason == nil ? nil : blockKind
        var found = false
        if var active = draft, active.id == id {
            active.serverDraftReference = reference
            active.previousServerDraftReference = previous
            active.serverDraftBlockedReason = blockedReason
            active.serverDraftBlockKind = blockKind
            active.serverDraftAcknowledgementUncertain = acknowledgementUncertain ? true : nil
            draft = active
            found = true
        }
        if var pending = pendingSend, pending.id == id {
            pending.serverDraftReference = reference
            pending.previousServerDraftReference = previous
            pending.serverDraftBlockedReason = blockedReason
            pending.serverDraftBlockKind = blockKind
            pending.serverDraftAcknowledgementUncertain = acknowledgementUncertain ? true : nil
            pendingSend = pending
            found = true
        }
        if let index = unsent.firstIndex(where: { $0.id == id }) {
            var item = unsent[index], changed = item.draft
            changed.serverDraftReference = reference
            changed.previousServerDraftReference = previous
            changed.serverDraftBlockedReason = blockedReason
            changed.serverDraftBlockKind = blockKind
            changed.serverDraftAcknowledgementUncertain = acknowledgementUncertain ? true : nil
            item = Unsent(draft: changed, reason: item.reason)
            unsent[index] = item
            found = true
        }
        for index in deliveries.indices where deliveries[index].id == id {
            guard var deliveryDraft = deliveries[index].draft else { continue }
            deliveryDraft.serverDraftReference = reference
            deliveryDraft.previousServerDraftReference = previous
            deliveryDraft.serverDraftBlockedReason = blockedReason
            deliveryDraft.serverDraftBlockKind = blockKind
            deliveryDraft.serverDraftAcknowledgementUncertain = acknowledgementUncertain ? true : nil
            deliveries[index].draft = deliveryDraft
            found = true
        }
        return found
    }

    /// Loads one selected native server draft into the composer. This is intentionally explicit:
    /// it never searches Drafts or turns every server row into a local draft.
    @discardableResult
    func editSelectedServerDraft() async throws -> Bool {
        guard MailBackend.current == .jevcast, NativeMailCenter.isActive else {
            throw LauncherError("Select Jevcast accounts as the mail source before editing a server draft.")
        }
        guard let selected, let box = mailbox(selected.mailbox), box.role == .drafts,
              box.serverRole == .drafts else {
            throw LauncherError("Select a message in the server Drafts folder to edit it.")
        }
        guard let engine = NativeMailCenter.activeEngine else {
            throw LauncherError("Add a mail account in Settings › Mail first.")
        }
        let loaded = try await engine.loadServerDraft(rowID: selected.rowID)
        guard selectedID == selected.rowID, MailBackend.current == .jevcast, NativeMailCenter.isActive else {
            throw LauncherError("The mail source changed while this server draft was loading. Open it again.")
        }
        let message = loaded.message
        let subject = message.header("Subject") ?? ""
        let sender = MailAddress.list(message.header("From") ?? "").first
        guard subject == selected.subject,
              sender?.address.caseInsensitiveCompare(selected.senderAddress) == .orderedSame,
              message.header("Message-ID") == loaded.reference.messageID else {
            throw LauncherError("The selected server draft changed. Open it again before editing it.")
        }
        guard let identity = senders.first(where: { $0.accountID == loaded.reference.accountID &&
                                                     $0.address.caseInsensitiveCompare(sender?.address ?? "") == .orderedSame }) else {
            throw LauncherError("The selected server draft's sending account is not available.")
        }

        let plain = message.plainText ?? message.html.map(HTMLText.plain) ?? ""
        let files = MIMEMessage.files(loaded.raw).map {
            OutgoingMessage.Attachment(filename: $0.name, mimeType: $0.mimeType, data: $0.data)
        }
        let inline = loaded.message.inlineImages.sorted { $0.key < $1.key }.map {
            OutgoingMessage.Attachment(filename: "inline-image", mimeType: $0.value.mimeType,
                                       data: $0.value.data, contentID: $0.key)
        }
        var draft = Draft()
        draft.backend = MailBackend.jevcast.rawValue
        draft.messageID = loaded.reference.messageID
        draft.fromAccountID = identity.accountID
        draft.fromAddress = identity.address
        draft.senderWasChosen = true
        draft.ownAddresses = senders.map(\ .address)
        draft.to = message.header("To") ?? ""
        draft.cc = message.header("Cc") ?? ""
        draft.bcc = message.header("Bcc") ?? ""
        draft.subject = subject
        draft.body = plain
        draft.attachments = inline + files
        draft.serverDraftReference = loaded.reference
        draft.serverDraftInReplyTo = message.header("In-Reply-To")
        draft.serverDraftReferences = MailReplies.messageIDs(message.header("References") ?? "")
        draft.serverDraftHTML = message.html
        draft.serverDraftHTMLBody = plain
        guard startDraft(draft) else { return false }
        return true
    }
}
