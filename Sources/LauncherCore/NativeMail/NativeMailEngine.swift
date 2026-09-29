import Foundation

/// Jevcast's own mail: one store and one sync per account. Changes show in the store at once and
/// go to the server right after; a change the server refuses is undone here too.
public actor NativeMailEngine {
    public nonisolated let store: NativeMailStore
    private let policy: MailSyncPolicy
    private let credential: @Sendable (NativeMailAccount) async throws -> MailCredential
    private let transport: IMAPClient.TransportFactory
    private let changed: @Sendable () -> Void
    private let report: @Sendable (String, MailAccountSync.State) -> Void
    private let notice: @Sendable (String, String) -> Void
    public private(set) var accounts: [NativeMailAccount] = []
    private var syncs: [String: MailAccountSync] = [:]

    public init(store: NativeMailStore, policy: MailSyncPolicy = MailSyncPolicy(),
                credential: @escaping @Sendable (NativeMailAccount) async throws -> MailCredential,
                transport: @escaping IMAPClient.TransportFactory = IMAPClient.networkTransport,
                changed: @escaping @Sendable () -> Void = {},
                report: @escaping @Sendable (String, MailAccountSync.State) -> Void = { _, _ in },
                notice: @escaping @Sendable (String, String) -> Void = { _, _ in }) {
        self.store = store; self.policy = policy; self.credential = credential; self.transport = transport
        self.changed = changed; self.report = report; self.notice = notice
    }

    // MARK: Accounts

    /// Starts sync for new accounts, stops it for removed ones, and starts it again for changed ones.
    public func setAccounts(_ list: [NativeMailAccount]) async {
        let old = syncs
        accounts = list
        var next: [String: MailAccountSync] = [:]
        for account in list {
            if let existing = old[account.id], existing.account == account { next[account.id] = existing; continue }
            if let existing = old[account.id] { await existing.stop() }
            let sync = makeSync(account)
            next[account.id] = sync
            await sync.start()
        }
        for (id, sync) in old where next[id] == nil { await sync.stop() }
        syncs = next
    }

    /// Starts an account's sync again, such as after a new password.
    public func restart(_ id: String) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        await syncs[id]?.stop()
        let sync = makeSync(account)
        syncs[id] = sync
        await sync.start()
    }

    public func stopAll() async {
        for sync in syncs.values { await sync.stop() }
        syncs = [:]
    }

    private func makeSync(_ account: NativeMailAccount) -> MailAccountSync {
        let credential = self.credential
        return MailAccountSync(account: account, store: store, policy: policy, credential: { try await credential(account) },
                               transport: transport, changed: changed, report: report, notice: notice)
    }

    /// Checks an account's servers and sign-in without adding it, for the Add Account sheet.
    public nonisolated func verify(_ account: NativeMailAccount, credential: MailCredential) async throws {
        let sync = MailAccountSync(account: account, store: store, credential: { credential }, transport: transport)
        defer { Task { await sync.stop() } }
        try await sync.verify()
    }

    /// Removes an account's mail from this Mac. The server keeps it.
    public func removeData(for id: String) async throws {
        await syncs[id]?.stop()
        syncs[id] = nil
        try await store.removeAccount(id)
        changed()
    }

    /// After sleep: every account connects again and checks at once.
    public func wake() async {
        for sync in syncs.values { await sync.wake() }
    }

    /// Asks every account to check now, such as when the inbox opens.
    public func sync(_ request: MailSyncRequest = .inboxOnly) async {
        for sync in syncs.values { await sync.request(request) }
    }

    // MARK: Changes

    private func target(_ rowID: Int64) async throws -> (NativeMailStore.Location, MailAccountSync) {
        guard let location = try await store.location(of: rowID) else { throw MailError.notFound("This message is no longer on this Mac.") }
        guard let sync = syncs[location.mailbox.account] else { throw MailError.notFound("This message's account is not set up.") }
        return (location, sync)
    }

    public func setRead(_ rowID: Int64, _ read: Bool) async throws {
        let (location, sync) = try await target(rowID)
        try await store.setLocal(rowID, read: read)
        changed()
        do { try await sync.setFlag("\\Seen", read, at: location) } catch {
            try? await store.setLocal(rowID, read: location.read)
            changed()
            throw error
        }
    }

    public func setFlagged(_ rowID: Int64, _ flagged: Bool) async throws {
        let (location, sync) = try await target(rowID)
        try await store.setLocal(rowID, flagged: flagged)
        changed()
        do { try await sync.setFlag("\\Flagged", flagged, at: location) } catch {
            try? await store.setLocal(rowID, flagged: location.flagged)
            changed()
            throw error
        }
    }

    /// Moves a message to another mailbox of its account, such as Archive.
    public func move(_ rowID: Int64, to mailboxRowID: Int64) async throws {
        let (location, sync) = try await target(rowID)
        guard let destination = try await store.mailbox(mailboxRowID), destination.account == location.mailbox.account else {
            throw MailError.notFound("Messages move only within one account.")
        }
        try await hide(location) { try await sync.move(location, to: destination) }
    }

    /// Moves a message to Trash, or deletes it for good when it is in Trash or there is no Trash.
    public func delete(_ rowID: Int64) async throws {
        let (location, sync) = try await target(rowID)
        let trash = try await store.mailboxes(account: location.mailbox.account).first { $0.role == .trash }
        try await hide(location) {
            if let trash, trash.rowID != location.mailbox.rowID { try await sync.move(location, to: trash) }
            else { try await sync.expunge(location) }
        }
    }

    /// Hides the row at once and drops it after the server's change; shows it again on failure.
    private func hide(_ location: NativeMailStore.Location, _ change: () async throws -> Void) async throws {
        try await store.setHidden(location.rowID, true)
        changed()
        do {
            try await change()
            try await store.remove(uids: [location.uid], from: location.mailbox.rowID)
            changed()
        } catch {
            try? await store.setHidden(location.rowID, false)
            changed()
            throw error
        }
    }

    /// Reads a body the store lacks. True when the message now has one on this Mac.
    @discardableResult
    public func fetchBody(_ rowID: Int64) async throws -> Bool {
        if try await store.hasBody(rowID) { return true }
        let (location, sync) = try await target(rowID)
        try await store.saveBody(rowID, raw: try await sync.body(location))
        changed()
        return true
    }

    private func original(_ rowID: Int64) async throws -> (NativeMailStore.Location, MailAccountSync, Data, MIMEMessage) {
        let (location, sync) = try await target(rowID)
        var raw = try await store.storedBody(rowID)
        if raw == nil {
            let fetched = try await sync.body(location)
            try? await store.saveBody(rowID, raw: fetched)
            raw = fetched
        }
        guard let raw, let message = MIMEMessage.parse(raw) else { throw MailError.notFound("This message could not be read.") }
        return (location, sync, raw, message)
    }

    // MARK: Sending

    /// A new message from `accountID`, or from the first account.
    public func send(from accountID: String? = nil, to: [String], cc: [String], subject: String, body: String) async throws {
        guard let account = accounts.first(where: { $0.id == accountID }) ?? accounts.first, let sync = syncs[account.id] else {
            throw MailError.notFound("Add a mail account in Settings › Mail first.")
        }
        var message = OutgoingMessage(from: account.sender, to: to.map { MailContact(address: $0) }, subject: subject, body: body)
        message.cc = cc.map { MailContact(address: $0) }
        try await sync.send(message)
    }

    public func reply(to rowID: Int64, text: String, all: Bool) async throws {
        let (location, sync, _, original) = try await original(rowID)
        let account = sync.account
        let (to, cc) = MailReplies.recipients(of: original, all: all, own: [account.email])
        guard !to.isEmpty else { throw MailError.notFound("This message has no address to reply to.") }
        let threading = MailReplies.references(of: original)
        var message = OutgoingMessage(from: account.sender, to: to, subject: MailReplies.replySubject(original.header("Subject") ?? ""),
                                      body: MailReplies.replyBody(text, original: original, sender: original.header("From") ?? "", date: location.date))
        message.cc = cc
        message.inReplyTo = threading.inReplyTo
        message.references = threading.references
        try await sync.send(message)
        try? await sync.setFlag("\\Answered", true, at: location)
    }

    /// Forwards the message's text; its attachments go along as the original message, attached.
    public func forward(_ rowID: Int64, text: String, to: [String]) async throws {
        let (location, sync, raw, original) = try await original(rowID)
        let account = sync.account
        guard !to.isEmpty else { throw MailError.notFound("Add at least one recipient.") }
        var message = OutgoingMessage(from: account.sender, to: to.map { MailContact(address: $0) },
                                      subject: MailReplies.forwardSubject(original.header("Subject") ?? ""),
                                      body: MailReplies.forwardBody(text, original: original, date: location.date))
        if !original.attachments.isEmpty {
            message.attachments = [.init(filename: "Forwarded message.eml", mimeType: "message/rfc822", data: raw)]
        }
        try await sync.send(message)
    }
}
