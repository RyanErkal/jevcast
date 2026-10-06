import Foundation

extension MailAccountSync {
    /// Refreshes the server listing and applies this account's current Sent mapping.
    /// Callers must not use the cached role alone for a filing decision.
    func currentSentMailboxes() async throws -> [NativeMailStore.Mailbox] {
        let entries = try await actionClient.listMailboxes()
        let listed = try await store.replaceMailboxes(account: account.id, with: entries,
                                                       roles: account.mailboxRoles ?? [:])
        mailboxes = listed
        return listed.filter { $0.role == .sent }
    }

    /// Repairs filing only. This method has no SMTP call.
    public func repairSentCopy(_ receipt: MailSendReceipt) async throws -> MailSendReceipt {
        guard receipt.accountID == account.id, receipt.sentCopy == .pending, let data = receipt.message,
              MailServerDraftSupport.validMessageID(receipt.messageID),
              let parsed = MIMEMessage.parse(data), parsed.header("Message-ID") == receipt.messageID else {
            throw MailError.notFound("The saved Sent copy does not belong to this account.")
        }
        let senders = MailAddress.list(parsed.header("From") ?? "")
        guard senders.count == 1, senders[0].address.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw MailError.notFound("The saved Sent copy does not belong to this account.")
        }

        // Refresh LIST and apply the current explicit/special-use mapping. A stale local role or
        // a renamed folder must never decide where an accepted message is filed.
        let candidates = try await currentSentMailboxes()
        guard candidates.count == 1, let sent = candidates.first else {
            throw MailError.notFound("Select one Sent folder in Settings › Mail.")
        }
        if let receiptMailbox = receipt.sentMailbox, receiptMailbox != sent.name {
            throw MailError.notFound("The Sent folder changed after this message was sent. Select the current Sent folder and try again.")
        }

        let info = try await actionClient.select(sent.name)
        if let known = sent.uidValidity, known != info.uidValidity { throw MailError.uidValidityChanged(mailbox: sent.name) }
        if let baselineValidity = receipt.sentUIDValidity, baselineValidity != info.uidValidity {
            throw MailError.uidValidityChanged(mailbox: sent.name)
        }
        guard info.uidValidity > 0 else { throw MailError.notFound("The Sent folder has no valid UIDVALIDITY. Try again after it finishes syncing.") }
        guard !info.readOnly else { throw MailError.notFound("The Sent folder is read only. No copy was added.") }
        guard let upper = info.uidNext else { throw MailError.notFound("The server did not report the Sent folder's UID range. Check Sent before repairing the copy.") }
        guard upper > 0 else { throw MailError.notFound("The server reported an invalid Sent UID range. Check Sent before repairing the copy.") }
        let baselineNext: UInt32?
        if let next = receipt.sentUIDNext {
            guard next > 0 else { throw MailError.notFound("This Sent-copy receipt has an invalid UID baseline. Check Sent before repairing the copy.") }
            guard receipt.sentUIDValidity != nil, receipt.sentMailbox != nil else {
                throw MailError.notFound("This Sent-copy receipt has an incomplete UID baseline. Check Sent before repairing the copy.")
            }
            guard upper >= next else { throw MailError.uidValidityChanged(mailbox: sent.name) }
            baselineNext = next
        } else {
            baselineNext = nil
        }
        let existing = try await actionClient.findMessageID(receipt.messageID, in: sent.name, validity: info.uidValidity,
                                                            before: upper, after: baselineNext)
        if existing.isEmpty {
            guard try await actionClient.append(data, to: sent.name, flags: ["\\Seen"], date: receipt.date) != nil else {
                throw MailError.deliveryUncertain
            }
        }
        await signal.post(MailSyncRequest(mailboxes: [sent.rowID]))
        return .init(accountID: account.id, messageID: receipt.messageID, sentCopy: .saved, date: receipt.date)
    }
}
