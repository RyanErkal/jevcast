import Foundation

extension MailAccountSync {
    /// Saves a raw RFC 5322 draft to the one server mailbox explicitly mapped as Drafts.
    /// Replacements append the new bytes first and remove the old UID only after the old bytes
    /// still match the returned reference.
    public func saveServerDraft(_ raw: Data, messageID: String,
                                replacing: MailServerDraftReference? = nil) async throws -> MailServerDraftReference {
        guard MailServerDraftSupport.validMessageID(messageID) else {
            throw MailServerDraftError.invalidMessageID
        }
        guard let parsed = MIMEMessage.parse(raw) else {
            throw MailServerDraftError.messageIDMismatch(expected: messageID, found: nil)
        }
        guard let foundMessageID = parsed.header("Message-ID"), foundMessageID == messageID else {
            throw MailServerDraftError.messageIDMismatch(expected: messageID, found: parsed.header("Message-ID"))
        }
        if let replacing {
            try validate(replacing)
            guard replacing.accountID == account.id else { throw MailServerDraftError.referenceAccountMismatch }
        }
        let digest = MailServerDraftSupport.digest(raw)

        try await actionClient.verify()
        guard await actionClient.has("UIDPLUS") else { throw MailServerDraftError.uidPlusRequired }
        let mailbox = try await mappedDraftsMailbox()
        let selected: IMAPClient.MailboxInfo
        do {
            selected = try await actionClient.select(mailbox.name)
        } catch MailError.commandFailed {
            throw MailServerDraftError.draftsMailboxMissing(accountID: account.id)
        }
        guard selected.readOnly == false else { throw MailServerDraftError.draftsMailboxReadOnly }
        guard selected.uidValidity != 0 else {
            throw MailServerDraftError.referenceUIDValidityChanged(expected: 1, actual: selected.uidValidity)
        }

        if let replacing {
            try validate(replacing, in: mailbox, selected: selected)
            try await verifyOwned(replacing, in: mailbox, selected: selected)
        }

        let newUID: UInt32
        do {
            newUID = try await actionClient.appendDraft(raw, to: mailbox.name, uidValidity: selected.uidValidity)
        } catch let uncertain as MailServerDraftError {
            if case .appendAcknowledgementUncertain = uncertain {
                let candidate = try? await actionClient.reconcileDraft(messageID: messageID, raw: raw,
                                                                        in: mailbox.name, uidValidity: selected.uidValidity).flatMap {
                    MailServerDraftReference(accountID: account.id, mailboxID: mailbox.rowID,
                                             uidValidity: selected.uidValidity, uid: $0,
                                             messageID: messageID, digest: digest)
                }
                throw MailServerDraftError.acknowledgementUncertain(messageID: messageID, digest: digest,
                                                                    candidate: candidate ?? nil, replacing: replacing)
            }
            throw uncertain
        }
        let reference = MailServerDraftReference(accountID: account.id, mailboxID: mailbox.rowID,
                                                 uidValidity: selected.uidValidity, uid: newUID,
                                                 messageID: messageID, digest: digest)

        guard let replacing else { return reference }
        do {
            // The old message can change while APPEND is in flight. Verify it again immediately
            // before deletion so an external edit is never treated as Jevcast's old draft.
            try await verifyOwned(replacing, in: mailbox, selected: selected)
            try await actionClient.removeDraft(uid: replacing.uid, from: mailbox.name, uidValidity: selected.uidValidity)
        } catch {
            throw MailServerDraftError.partialReplacement(previous: replacing, new: reference,
                                                           reason: MailServerDraftSupport.errorText(error))
        }
        return reference
    }

    /// Removes only the exact server draft this account previously returned.
    public func removeServerDraft(_ reference: MailServerDraftReference) async throws {
        try validate(reference)
        guard reference.accountID == account.id else { throw MailServerDraftError.referenceAccountMismatch }

        try await actionClient.verify()
        guard await actionClient.has("UIDPLUS") else { throw MailServerDraftError.uidPlusRequired }
        let mailbox = try await mappedDraftsMailbox()
        guard mailbox.rowID == reference.mailboxID else { throw MailServerDraftError.referenceMailboxMismatch }
        let selected: IMAPClient.MailboxInfo
        do {
            selected = try await actionClient.select(mailbox.name)
        } catch MailError.commandFailed {
            throw MailServerDraftError.draftsMailboxMissing(accountID: account.id)
        }
        guard selected.uidValidity == reference.uidValidity else {
            throw MailServerDraftError.referenceUIDValidityChanged(expected: reference.uidValidity,
                                                                   actual: selected.uidValidity)
        }
        guard selected.readOnly == false else { throw MailServerDraftError.draftsMailboxReadOnly }
        try await verifyOwned(reference, in: mailbox, selected: selected)
        do {
            try await actionClient.removeDraft(uid: reference.uid, from: mailbox.name, uidValidity: selected.uidValidity)
        } catch {
            if Task.isCancelled || IMAPClient.isConnectionError(error) {
                throw MailServerDraftError.removalUncertain(reference)
            }
            throw error
        }
    }

    // MARK: Mapping and ownership

    /// Refreshes the mapping before each mutation so renamed or missing Drafts folders cannot
    /// silently fall back to a similarly named mailbox.
    private func mappedDraftsMailbox() async throws -> NativeMailStore.Mailbox {
        let entries = try await actionClient.listMailboxes()
        let listed = try await store.replaceMailboxes(account: account.id, with: entries,
                                                      roles: account.mailboxRoles ?? [:])
        mailboxes = listed
        let drafts = listed.filter { $0.role == .drafts }
        guard drafts.count == 1, let mailbox = drafts.first else {
            if drafts.isEmpty { throw MailServerDraftError.draftsMailboxMissing(accountID: account.id) }
            throw MailServerDraftError.draftsMailboxNotUnique(accountID: account.id)
        }
        return mailbox
    }

    private func validate(_ reference: MailServerDraftReference) throws {
        guard NativeMailStore.isSafeName(reference.accountID), reference.mailboxID > 0,
              reference.uidValidity > 0, reference.uid > 0,
              reference.digest.count == 64,
              reference.digest.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
              MailServerDraftSupport.validMessageID(reference.messageID) else {
            throw MailServerDraftError.invalidReference
        }
    }

    private func validate(_ reference: MailServerDraftReference, in mailbox: NativeMailStore.Mailbox,
                          selected: IMAPClient.MailboxInfo) throws {
        try validate(reference)
        guard reference.accountID == account.id else { throw MailServerDraftError.referenceAccountMismatch }
        guard reference.mailboxID == mailbox.rowID else { throw MailServerDraftError.referenceMailboxMismatch }
        guard reference.uidValidity == selected.uidValidity else {
            throw MailServerDraftError.referenceUIDValidityChanged(expected: reference.uidValidity,
                                                                   actual: selected.uidValidity)
        }
    }

    private func verifyOwned(_ reference: MailServerDraftReference, in mailbox: NativeMailStore.Mailbox,
                             selected: IMAPClient.MailboxInfo) async throws {
        let body: Data?
        do {
            body = try await actionClient.draftBody(uid: reference.uid, in: mailbox.name,
                                                    uidValidity: selected.uidValidity)
        } catch MailError.uidValidityChanged {
            throw MailServerDraftError.referenceUIDValidityChanged(expected: reference.uidValidity, actual: nil)
        }
        guard let body else { throw MailServerDraftError.referenceNotFound(reference) }
        guard MailServerDraftSupport.digest(body) == reference.digest,
              MIMEMessage.parse(body)?.header("Message-ID") == reference.messageID else {
            throw MailServerDraftError.ownedDraftChanged(reference)
        }
    }
}
