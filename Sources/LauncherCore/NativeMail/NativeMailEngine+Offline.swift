import Foundation

extension NativeMailEngine {
    func offlineAction(for location: NativeMailStore.Location, kind: MailOfflineActionKind,
                       destination: NativeMailStore.Mailbox? = nil, desiredValue: Bool? = nil) -> MailOfflineAction? {
        guard let validity = location.mailbox.uidValidity else { return nil }
        // A destination may not have been selected on this Mac yet. Keep its server name and
        // capture UIDVALIDITY when it is known; replay still validates the source identity before
        // issuing the move and checks any captured destination identity.
        if (kind == .move || kind == .archive), destination?.name.isEmpty ?? true { return nil }
        return MailOfflineAction(accountID: location.mailbox.account, kind: kind,
                                 mailboxName: location.mailbox.name, uidValidity: validity, uid: location.uid,
                                 messageID: location.messageID,
                                 destinationMailboxName: destination?.name,
                                 destinationUIDValidity: destination?.uidValidity,
                                 desiredValue: desiredValue)
    }

    func queueOfflineAction(for location: NativeMailStore.Location, kind: MailOfflineActionKind,
                            desiredValue: Bool, error: Error) async -> Bool {
        guard let action = offlineAction(for: location, kind: kind, desiredValue: desiredValue) else { return false }
        return await queueOfflineAction(action, error: error)
    }

    /// Read/flag failures may wait for a reconnect. A move is held for review whenever a
    /// connection ended after the command could have reached the server. Explicit offline mode
    /// is the one case where a pending move is known not to have been sent.
    func queueOfflineAction(_ action: MailOfflineAction, error: Error) async -> Bool {
        let transient = MailIOPolicy.isOffline || (error as? MailError)?.canQueueOffline == true || error is MailTransportError
        guard transient else { return false }
        var queued = action
        if (action.kind == .move || action.kind == .archive) && !MailIOPolicy.isOffline {
            queued.state = .review
            queued.lastError = "The move could not be confirmed. Check both folders before trying again."
        } else {
            queued.state = .pending
            queued.lastError = error.localizedDescription
        }
        do {
            _ = try await store.enqueueOfflineAction(queued)
            changed()
            return true
        } catch {
            return false
        }
    }

    /// The launcher can call this after an account reconnects or after a user retries a failed
    /// queued action. Review items are intentionally untouched.
    public func reconcileOfflineActions() async {
        for sync in syncs.values { await sync.replayOfflineActions() }
        changed()
    }

    public func offlineActions(accountID: String? = nil) async -> [MailOfflineAction] {
        (try? await store.offlineActions(accountID: accountID)) ?? []
    }
}
