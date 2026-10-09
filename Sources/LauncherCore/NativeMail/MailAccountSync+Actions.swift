import Foundation

/// Changes you make, on the account's action connection, so they never wait behind sync.
extension MailAccountSync {
    func validity(_ location: NativeMailStore.Location) throws -> UInt32 {
        guard let validity = location.mailbox.uidValidity else { throw MailError.notFound("This message has not finished syncing.") }
        return validity
    }

    public func setFlag(_ flag: String, _ on: Bool, at location: NativeMailStore.Location) async throws {
        try await actionClient.store(uids: IMAPSequenceSet([location.uid]), add: on, flags: [flag],
                                     in: location.mailbox.name, validity: try validity(location))
    }

    public func move(_ location: NativeMailStore.Location, to destination: NativeMailStore.Mailbox) async throws {
        try await actionClient.move(uids: IMAPSequenceSet([location.uid]), to: destination.name,
                                    in: location.mailbox.name, validity: try validity(location))
        await signal.post(MailSyncRequest(mailboxes: [destination.rowID]))
    }

    /// Removes one message for good, by its UID. Only for a message already in Trash, after the user confirmed.
    public func deletePermanently(_ location: NativeMailStore.Location) async throws {
        try await actionClient.deletePermanently(uids: IMAPSequenceSet([location.uid]), in: location.mailbox.name, validity: try validity(location))
    }

    /// Every message in `box` on the server now, by UID, read in ranges inside its MESSAGELIMIT.
    /// The list is what Empty removes, so mail that arrives after the count stays.
    public func contents(of box: NativeMailStore.Mailbox) async throws -> (uids: [UInt32], validity: UInt32) {
        let info = try await actionClient.select(box.name)
        if let known = box.uidValidity, known != info.uidValidity { throw MailError.uidValidityChanged(mailbox: box.name) }
        let found = try await newestUIDs(.max, below: info.uidNext ?? .max, above: 0, in: box.name, validity: info.uidValidity, client: actionClient)
        return (found.uids, info.uidValidity)
    }

    /// Removes exactly `uids` from `box` for good.
    public func empty(_ box: NativeMailStore.Mailbox, uids: [UInt32], validity: UInt32) async throws {
        try await actionClient.deletePermanently(uids: IMAPSequenceSet(uids), in: box.name, validity: validity)
    }

    /// The whole message from the server, for opening, replying, or forwarding.
    public func body(_ location: NativeMailStore.Location) async throws -> Data {
        let fetched = try await actionClient.fetch(uids: IMAPSequenceSet([location.uid]), items: "(UID BODY.PEEK[])",
                                                   in: location.mailbox.name, validity: try validity(location))
        guard let raw = fetched.first(where: { $0.uid == location.uid })?.message else {
            throw MailError.notFound("The server no longer has this message.")
        }
        return raw
    }

    /// Sends through SMTP, then files a copy in Sent when the server does not do that itself. A
    /// copy that cannot be filed does not undo the send; it is reported as a notice.
    @discardableResult
    public func send(_ message: OutgoingMessage, verifiedSender: NativeMailSender? = nil) async throws -> MailSendReceipt {
        let sender: NativeMailSender
        if let verifiedSender {
            guard message.from.address.caseInsensitiveCompare(verifiedSender.address) == .orderedSame else {
                throw MailError.notFound("The selected sending identity changed before delivery.")
            }
            sender = try verifiedSender.validated(for: account)
        } else {
            guard message.from.address.caseInsensitiveCompare(account.email) == .orderedSame else {
                throw MailError.notFound("A native message must use the account address or a verified provider alias.")
            }
            sender = .canonical(for: account)
        }
        let data = MailComposer.render(message)
        try await smtp.send(from: account.email, recipients: message.recipients, message: data)
        func pending(_ note: String, sent: NativeMailStore.Mailbox? = nil,
                     info: IMAPClient.MailboxInfo? = nil, attempted: Bool) -> MailSendReceipt {
            .init(accountID: account.id, messageID: message.messageID, sentCopy: .pending, note: note, message: data,
                  date: message.date,
                  sentMailbox: sent?.name, sentUIDValidity: info?.uidValidity, sentUIDNext: info?.uidNext,
                  filingAttempted: attempted, sender: sender)
        }
        guard account.savesSentCopy else {
            let sentIDs = Set(mailboxes.filter { $0.role == .sent }.map(\.rowID))
            if !sentIDs.isEmpty { await signal.post(MailSyncRequest(mailboxes: sentIDs)) }
            return .init(accountID: account.id, messageID: message.messageID, sentCopy: .serverManaged,
                         date: message.date, sender: sender)
        }
        let candidates: [NativeMailStore.Mailbox]
        do {
            candidates = try await currentSentMailboxes()
        } catch {
            let note = "Sent, but the copy could not be started: " + error.localizedDescription
            notice(account.id, note)
            return pending(note, attempted: false)
        }
        guard candidates.count == 1, let sent = candidates.first else {
            let note = "Sent, but no copy was saved. Select one Sent folder in Settings › Mail."
            notice(account.id, note)
            return pending(note, attempted: false)
        }
        let baseline: IMAPClient.MailboxInfo
        do {
            let info = try await actionClient.select(sent.name)
            guard info.uidValidity > 0 else { throw MailError.notFound("The Sent folder has no valid UIDVALIDITY.") }
            guard !info.readOnly else { throw MailError.notFound("The Sent folder is read only.") }
            if let known = sent.uidValidity, known != info.uidValidity { throw MailError.uidValidityChanged(mailbox: sent.name) }
            baseline = info
        } catch {
            let note = "Sent, but the copy could not be started: " + error.localizedDescription
            notice(account.id, note)
            return pending(note, sent: sent, attempted: false)
        }
        do {
            // APPEND without APPENDUID is not proof that the server did not save the copy. Keep
            // the accepted message and its raw bytes pending; never turn an ambiguous result into
            // a second APPEND or a resend.
            guard try await actionClient.append(data, to: sent.name, flags: ["\\Seen"], date: message.date) != nil else {
                throw MailError.deliveryUncertain
            }
            await signal.post(MailSyncRequest(mailboxes: [sent.rowID]))
            return .init(accountID: account.id, messageID: message.messageID, sentCopy: .saved,
                         date: message.date,
                         sentMailbox: sent.name, sentUIDValidity: baseline.uidValidity,
                         sentUIDNext: baseline.uidNext, filingAttempted: true, sender: sender)
        } catch {
            let note = "Sent, but the copy in Sent could not be saved: " + error.localizedDescription
            notice(account.id, note)
            return pending(note, sent: sent, info: baseline, attempted: true)
        }
    }

    /// Checks the incoming and outgoing servers and the sign-in, for Settings.
    public func verify() async throws {
        try await actionClient.verify()
        try await smtp.verify()
    }
}
