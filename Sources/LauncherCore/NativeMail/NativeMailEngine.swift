import Foundation

/// Jevcast's own mail: one store and one sync per account. Changes show in the store at once and
/// go to the server right after; a change the server refuses is undone here too.
public actor NativeMailEngine {
    public nonisolated let store: NativeMailStore
    private let policy: MailSyncPolicy
    private let credential: @Sendable (NativeMailAccount) async throws -> MailCredential
    private let transport: IMAPClient.TransportFactory
    let changed: @Sendable () -> Void
    private let report: @Sendable (String, MailAccountSync.State) -> Void
    private let notice: @Sendable (String, String) -> Void
    public private(set) var accounts: [NativeMailAccount] = []
    var syncs: [String: MailAccountSync] = [:]

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

    /// Wakes the existing retry loop without replacing connections or other accounts.
    public func syncAccount(_ id: String) async {
        await syncs[id]?.request(.everything)
    }

    /// Reads one older batch of a mailbox when its list reaches the end of what this Mac has.
    /// Returns whether the server holds older mail still.
    public func loadOlder(_ mailboxRowID: Int64) async throws -> Bool {
        for sync in syncs.values {
            if let more = try await sync.loadOlder(mailboxRowID) { return more }
        }
        return false
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
            if await queueOfflineAction(for: location, kind: .read, desiredValue: read, error: error) { return }
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
            if await queueOfflineAction(for: location, kind: .flag, desiredValue: flagged, error: error) { return }
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
        if destination.rowID == location.mailbox.rowID { return }
        let action = offlineAction(for: location, kind: .move, destination: destination)
        try await hide(location, movingTo: destination, offlineAction: action) { try await sync.move(location, to: destination) }
    }

    /// Delete moves a message to its account's one Trash. A message already in Trash is removed for
    /// good only with `permanently`, which the app passes after you confirm; without it, it is refused.
    public func delete(_ rowID: Int64, permanently: Bool = false) async throws {
        let (location, sync) = try await target(rowID)
        let candidates = try await store.mailboxes(account: location.mailbox.account).filter { $0.role == .trash }
        guard candidates.count == 1, let trash = candidates.first else {
            throw MailError.notFound("Select one Trash mailbox in Settings › Mail. Nothing was deleted.")
        }
        guard trash.rowID != location.mailbox.rowID else {
            guard permanently else { throw MailError.notFound("This message is already in Trash. Delete it again to remove it permanently.") }
            try await hide(location) { try await sync.deletePermanently(location) }
            return
        }
        let action = offlineAction(for: location, kind: .move, destination: trash)
        try await hide(location, movingTo: trash, offlineAction: action) { try await sync.move(location, to: trash) }
    }

    /// What Empty would remove from a Trash or Junk mailbox now, for the confirmation's count.
    public func contents(of mailboxRowID: Int64) async throws -> (uids: [UInt32], validity: UInt32) {
        let (box, sync) = try await emptiable(mailboxRowID)
        return try await sync.contents(of: box)
    }

    /// Removes exactly `uids`, the list you confirmed, from a Trash or Junk mailbox for good.
    public func empty(_ mailboxRowID: Int64, uids: [UInt32], validity: UInt32) async throws {
        let (box, sync) = try await emptiable(mailboxRowID)
        try await sync.empty(box, uids: uids, validity: validity)
        try await store.remove(uids: uids, from: box.rowID, removedHere: true,
                               protectFromStaleSync: true, uidValidity: validity)
        changed()
        await sync.request(MailSyncRequest(mailboxes: [box.rowID]))
    }

    private func emptiable(_ rowID: Int64) async throws -> (NativeMailStore.Mailbox, MailAccountSync) {
        guard let box = try await store.mailbox(rowID), box.role == .trash || box.role == .junk else {
            throw MailError.notFound("Only Trash and Junk can be emptied. Nothing was deleted.")
        }
        guard let sync = syncs[box.account] else { throw MailError.notFound("This mailbox's account is not set up.") }
        return (box, sync)
    }

    /// Hides the row at once and drops it after the server's change; shows it again on failure.
    /// A move counts the message into its destination's server counts.
    private func hide(_ location: NativeMailStore.Location, movingTo destination: NativeMailStore.Mailbox? = nil,
                      offlineAction: MailOfflineAction? = nil,
                      _ change: () async throws -> Void) async throws {
        try await store.setHidden(location.rowID, true)
        changed()
        do {
            try await change()
            if let destination { try? await store.adjustServerCounts(destination.rowID, total: 1, unread: location.read ? 0 : 1) }
            try await store.remove(uids: [location.uid], from: location.mailbox.rowID,
                                   protectFromStaleSync: true, uidValidity: location.mailbox.uidValidity)
            changed()
        } catch {
            if let offlineAction, await queueOfflineAction(offlineAction, error: error) {
                // Keep the row hidden while the durable action waits. A reconnect either removes
                // it after a confirmed move or leaves it in review for an explicit user choice.
                return
            }
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

    /// Who a message goes to, as the composer shows it, with display names.
    public struct Recipients: Sendable, Equatable {
        public var to: [MailContact], cc: [MailContact], bcc: [MailContact]
        public init(to: [MailContact], cc: [MailContact] = [], bcc: [MailContact] = []) { self.to = to; self.cc = cc; self.bcc = bcc }
    }

    /// A new message from the explicitly selected account. `recipients`, when given, replaces `to`
    /// and `cc` and adds Bcc.
    @discardableResult
    public func send(from accountID: String, to: [String], cc: [String], subject: String, body: String,
                     html: String? = nil, attachments: [OutgoingMessage.Attachment] = [], messageID: String? = nil,
                     recipients: Recipients? = nil, inReplyTo: String? = nil,
                     references: [String] = [], sender: NativeMailSender? = nil) async throws -> MailSendReceipt {
        let sync = try sendingSync(accountID)
        let account = sync.account
        let verifiedSender = try (sender ?? .canonical(for: account)).validated(for: account)
        let chosen = recipients ?? Recipients(to: to.map { MailContact(address: $0) }, cc: cc.map { MailContact(address: $0) })
        var message = OutgoingMessage(from: verifiedSender.contact, to: chosen.to, subject: subject, body: body)
        message.cc = chosen.cc; message.bcc = chosen.bcc
        message.html = html; message.attachments = attachments
        message.inReplyTo = inReplyTo; message.references = references
        if let messageID { message.messageID = messageID }
        return try await sync.send(message, verifiedSender: verifiedSender)
    }

    /// A reply. The composer's `recipients` and `subject` win over the ones worked out from the
    /// original. Without `quote`, only your text goes. `saved` is the original as the draft kept it:
    /// it answers a message moved or deleted during the undo time.
    @discardableResult
    public func reply(to rowID: Int64, text: String, all: Bool, from accountID: String, html: String? = nil,
                      attachments: [OutgoingMessage.Attachment] = [], messageID: String? = nil, expectedMessageID: String? = nil,
                      recipients: Recipients? = nil, subject: String? = nil, quote: Bool = true,
                      saved: MIMEMessage? = nil, savedDate: Date? = nil,
                      sender: NativeMailSender? = nil) async throws -> MailSendReceipt {
        let sending = try sendingSync(accountID)
        let verifiedSender = try (sender ?? .canonical(for: sending.account)).validated(for: sending.account)
        let answered = try await answered(rowID, expectedMessageID: expectedMessageID, saved: saved, savedDate: savedDate, verb: "replying")
        let original = answered.message
        // Treat the explicitly verified alias as one of this account's own addresses for Reply
        // All. Do not reject it by comparing the selected address to the canonical account email.
        let own = Set(accounts.map(\.email) + [verifiedSender.address])
        let worked = MailReplies.recipients(of: original, all: all, own: own)
        let chosen = recipients ?? Recipients(to: worked.to, cc: worked.cc)
        guard !chosen.to.isEmpty else { throw MailError.notFound("This message has no address to reply to.") }
        let sender = original.header("From") ?? ""
        let threading = MailReplies.references(of: original)
        var message = OutgoingMessage(from: verifiedSender.contact, to: chosen.to, subject: subject ?? MailReplies.replySubject(original.header("Subject") ?? ""),
                                      body: MailReplies.replyBody(text, original: original, sender: sender, date: answered.date, quote: quote))
        message.cc = chosen.cc; message.bcc = chosen.bcc
        message.inReplyTo = threading.inReplyTo
        message.references = threading.references
        message.html = (html ?? MailHTML.plain(text))
            + (quote ? MailHTML.quoted(original, attribution: MailReplies.replyAttribution(date: answered.date, sender: sender)) : "")
        message.attachments = attachments + (quote ? Self.inlineAttachments(original) : [])
        if let messageID { message.messageID = messageID }
        let receipt = try await sending.send(message, verifiedSender: verifiedSender)
        if let location = answered.location, let sync = answered.sync { try? await sync.setFlag("\\Answered", true, at: location) }
        return receipt
    }

    /// A forward: your text, the original's headers and HTML, and its attachments one by one.
    @discardableResult
    public func forward(_ rowID: Int64, text: String, to: [String], from accountID: String, html: String? = nil,
                        attachments: [OutgoingMessage.Attachment] = [], messageID: String? = nil, expectedMessageID: String? = nil,
                        recipients: Recipients? = nil, subject: String? = nil, saved: MIMEMessage? = nil, savedDate: Date? = nil,
                        savedAttachments: [OutgoingMessage.Attachment]? = nil,
                        sender: NativeMailSender? = nil) async throws -> MailSendReceipt {
        let sending = try sendingSync(accountID)
        let verifiedSender = try (sender ?? .canonical(for: sending.account)).validated(for: sending.account)
        let answered = try await answered(rowID, expectedMessageID: expectedMessageID, saved: saved, savedDate: savedDate, verb: "forwarding")
        let original = answered.message
        let chosen = recipients ?? Recipients(to: to.map { MailContact(address: $0) })
        guard !chosen.to.isEmpty else { throw MailError.notFound("Add at least one recipient.") }
        let files = answered.raw.map(MIMEMessage.files)?.map { OutgoingMessage.Attachment(filename: $0.name, mimeType: $0.mimeType, data: $0.data) }
            ?? savedAttachments ?? []
        // A file the forward cannot carry must not vanish without a word.
        guard files.count >= original.attachments.count else {
            throw MailError.notFound("The original message moved before it could be forwarded with its attachments. Open it again and forward it.")
        }
        var message = OutgoingMessage(from: verifiedSender.contact, to: chosen.to, subject: subject ?? MailReplies.forwardSubject(original.header("Subject") ?? ""),
                                      body: MailReplies.forwardBody(text, original: original, date: answered.date))
        message.cc = chosen.cc; message.bcc = chosen.bcc
        message.html = (html ?? MailHTML.plain(text)) + MailHTML.forwarded(original, date: MailReplies.attribution(answered.date))
        message.attachments = attachments + Self.inlineAttachments(original)
            + files
        if let messageID { message.messageID = messageID }
        return try await sending.send(message, verifiedSender: verifiedSender)
    }

    /// The message being answered: from this Mac and its server, or, once it left this Mac, the copy
    /// the draft kept. A message that changed under its row is refused.
    private func answered(_ rowID: Int64, expectedMessageID: String?, saved: MIMEMessage?, savedDate: Date?, verb: String) async throws
        -> (message: MIMEMessage, raw: Data?, date: Date, location: NativeMailStore.Location?, sync: MailAccountSync?) {
        if let saved, try await store.location(of: rowID) == nil {
            return (saved, nil, savedDate ?? Date(), nil, nil)
        }
        let (location, sync, raw, message) = try await original(rowID)
        if let expectedMessageID, message.header("Message-ID") != expectedMessageID {
            throw MailError.notFound("The original message changed. Open it again before \(verb).")
        }
        return (message, raw, location.date, location, sync)
    }

    private func sendingSync(_ id: String) throws -> MailAccountSync {
        guard let sync = syncs[id], accounts.contains(where: { $0.id == id }) else {
            throw MailError.notFound("The selected sending account is not available. Nothing was sent.")
        }
        return sync
    }

    func accountSync(_ id: String) throws -> MailAccountSync { try sendingSync(id) }

    private static func inlineAttachments(_ message: MIMEMessage) -> [OutgoingMessage.Attachment] {
        message.inlineImages.sorted { $0.key < $1.key }.map { id, image in
            .init(filename: "inline-image", mimeType: image.mimeType, data: image.data, contentID: id)
        }
    }
}
