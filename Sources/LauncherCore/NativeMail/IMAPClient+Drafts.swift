import Foundation

extension IMAPClient {
    /// APPEND a draft with a UIDPLUS acknowledgement. This is deliberately never retried: after
    /// the literal is written, a lost response leaves the result uncertain instead of duplicating
    /// the draft on a new connection.
    func appendDraft(_ raw: Data, to mailbox: String, uidValidity: UInt32) async throws -> UInt32 {
        return try await exclusive(retry: false) {
            guard has("UIDPLUS") else { throw MailServerDraftError.uidPlusRequired }
            let selected = try await ensureSelected(mailbox, validity: uidValidity)
            guard selected.readOnly == false else { throw MailServerDraftError.draftsMailboxReadOnly }
            var command = IMAPCommand("APPEND").mailbox(mailbox).raw("(\\Draft)")
            command = command.literal(raw)
            var issued = false
            do {
                issued = true
                let reply = try await execute(command)
                guard let code = reply.status.code, code.name == "APPENDUID", code.values.count == 2,
                      let actualValidity = code.values[0].number.flatMap({ UInt32(exactly: $0) }),
                      let uid = code.values[1].number.flatMap({ UInt32(exactly: $0) }), uid > 0,
                      actualValidity == uidValidity else {
                    throw MailServerDraftError.appendAcknowledgementUncertain(mailbox: mailbox, uidValidity: uidValidity)
                }
                return uid
            } catch {
                if issued && (error is CancellationError || Self.isConnectionError(error)) {
                    throw MailServerDraftError.appendAcknowledgementUncertain(mailbox: mailbox, uidValidity: uidValidity)
                }
                throw error
            }
        }
    }

    /// Reads exactly one UID without changing flags. The caller verifies the body digest and
    /// Message-ID before any delete.
    func draftBody(uid: UInt32, in mailbox: String, uidValidity: UInt32) async throws -> Data? {
        let fetched = try await fetch(uids: IMAPSequenceSet([uid]), items: "(UID BODY.PEEK[])",
                                      in: mailbox, validity: uidValidity)
        return fetched.first(where: { $0.uid == uid })?.message
    }

    /// Removes exactly one draft UID through UID STORE + UID EXPUNGE. The existing deletion
    /// primitive refuses missing UIDPLUS, uses no retry, and never issues blanket EXPUNGE/CLOSE.
    func removeDraft(uid: UInt32, from mailbox: String, uidValidity: UInt32) async throws {
        try await deletePermanently(uids: IMAPSequenceSet([uid]), in: mailbox, validity: uidValidity)
    }

    /// Reconciles an uncertain APPEND only within a recent, bounded UID range. The final raw-body
    /// and Message-ID checks are still required because SEARCH criteria can be broader on servers.
    func reconcileDraft(messageID: String, raw: Data, in mailbox: String, uidValidity: UInt32) async throws -> UInt32? {
        guard MailServerDraftSupport.validMessageID(messageID) else { throw MailServerDraftError.invalidMessageID }
        // A lost APPEND acknowledgement normally drops the connection. Select through the public
        // command path so reconciliation can reconnect once, while the APPEND itself is never
        // retried.
        let info = try await select(mailbox)
        guard info.uidValidity == uidValidity else {
            throw MailError.uidValidityChanged(mailbox: mailbox)
        }
        guard let uidNext = info.uidNext, uidNext > 1 else { return nil }
        let upper = uidNext - 1
        let bound = max(1, min(messageLimit ?? 1_000, 1_000))
        let lower = upper > UInt32(bound - 1) ? upper - UInt32(bound - 1) : 1
        let criteria = "UID \(lower):\(upper) HEADER Message-ID \(IMAPCommand.quoted(messageID))"
        let found = try await search(criteria, in: mailbox, validity: uidValidity)
        guard found.count <= bound else { throw MailServerDraftError.reconciliationBoundExceeded }
        let matches = try await fetch(uids: found, items: "(UID BODY.PEEK[])", in: mailbox, validity: uidValidity).compactMap { item -> UInt32? in
            guard let uid = item.uid, let body = item.message,
                  MailServerDraftSupport.digest(body) == MailServerDraftSupport.digest(raw),
                  MIMEMessage.parse(body)?.header("Message-ID") == messageID else { return nil }
            return uid
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
