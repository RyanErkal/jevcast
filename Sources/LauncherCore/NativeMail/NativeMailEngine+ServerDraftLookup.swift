import Foundation

extension NativeMailEngine {
    /// Fetches one selected server draft and establishes ownership from the current mailbox row,
    /// UIDVALIDITY, UID, Message-ID, and raw-body digest. It never searches or loads all Drafts.
    public func loadServerDraft(rowID: Int64) async throws
        -> (raw: Data, reference: MailServerDraftReference, message: MIMEMessage) {
        guard let location = try await store.location(of: rowID), location.mailbox.role == .drafts else {
            throw MailError.notFound("Select a message in the server Drafts folder to edit it.")
        }
        guard let uidValidity = location.mailbox.uidValidity, uidValidity > 0 else {
            throw MailError.notFound("This server draft has not finished syncing. Try again after Drafts updates.")
        }
        let sync = try accountSync(location.mailbox.account)
        // Always fetch the selected UID. A local body can be stale after another device edits it,
        // and stale bytes must never become an owned replacement reference.
        let raw = try await sync.body(location)
        guard let message = MIMEMessage.parse(raw),
              let messageID = message.header("Message-ID"),
              MailServerDraftSupport.validMessageID(messageID) else {
            throw MailError.notFound("This server draft has no valid Message-ID. It was not opened.")
        }
        let reference = MailServerDraftReference(accountID: location.mailbox.account,
                                                  mailboxID: location.mailbox.rowID,
                                                  uidValidity: uidValidity, uid: location.uid,
                                                  messageID: messageID,
                                                  digest: MailServerDraftSupport.digest(raw))
        // Keeping the exact bytes locally makes the next open immediate. The fetched bytes above
        // remain authoritative even if this cache write fails.
        try? await store.saveBody(rowID, raw: raw)
        return (raw, reference, message)
    }
}
