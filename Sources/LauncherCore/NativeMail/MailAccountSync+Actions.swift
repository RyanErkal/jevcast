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

    /// Deletes for good, as from Trash, or when the account has no Trash.
    public func expunge(_ location: NativeMailStore.Location) async throws {
        try await actionClient.expunge(uids: IMAPSequenceSet([location.uid]), in: location.mailbox.name, validity: try validity(location))
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
    public func send(_ message: OutgoingMessage) async throws {
        let data = MailComposer.render(message)
        try await smtp.send(from: account.email, recipients: message.recipients, message: data)
        guard account.savesSentCopy else { return }
        guard let sent = mailboxes.first(where: { $0.role == .sent }) else {
            notice(account.id, "Sent, but this account has no Sent mailbox for a copy.")
            return
        }
        do {
            try await actionClient.append(data, to: sent.name, flags: ["\\Seen"], date: message.date)
            await signal.post(MailSyncRequest(mailboxes: [sent.rowID]))
        } catch {
            notice(account.id, "Sent, but the copy in Sent could not be saved: " + error.localizedDescription)
        }
    }

    /// Checks the incoming and outgoing servers and the sign-in, for Settings.
    public func verify() async throws {
        try await actionClient.verify()
        try await smtp.verify()
    }
}
