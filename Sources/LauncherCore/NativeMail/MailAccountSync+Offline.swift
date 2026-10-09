import Foundation

extension MailError {
    /// A failure that means a later connection may be useful. The caller still treats a move as
    /// uncertain because the server may have applied it before the connection ended.
    var canQueueOffline: Bool {
        switch self {
        case .serverClosed, .idleUnsupported: return true
        case .commandFailed(_, let status, _): return status == .bad || status == .bye
        default: return false
        }
    }
}

extension MailAccountSync {
    /// One bounded background step. Normal inbox/folder sync remains responsible for the current
    /// list; this method only advances history/body coverage selected by the offline policy.
    func runOfflineWork() async throws -> Bool {
        let offline = try await store.offlinePolicy(for: account.id)
        guard !offline.paused else { return false }
        var more = false
        let targets: [NativeMailStore.Mailbox]
        switch offline.mode {
        case .recent:
            // Recent mode keeps the existing bounded inbox behavior. It does not walk older
            // history, but it still applies the body settings to the selected recent window.
            targets = mailboxes.filter { $0.role == .inbox }
        case .selectedFolders:
            targets = mailboxes.filter { offline.selectedFolderNames.contains($0.name) }
        case .allHistory:
            targets = mailboxes
        }
        // At most one history page per pass prevents a large account from starving new mail.
        if offline.mode != .recent || offline.recentMessageLimit != MailOfflinePolicy.default.recentMessageLimit {
            for box in targets {
                if offline.mode == .recent, try await store.uidCount(box.rowID) >= offline.recentMessageLimit { continue }
                try Task.checkCancellation()
                if !box.complete, try await loadOlder(box.rowID) == true {
                    more = true
                    break
                }
            }
        }
        guard offline.indexBodies || offline.downloadAttachments else { return more }
        // Body indexing is also bounded. Opened messages are fetched by the normal path; these
        // rows are only the policy-selected background cache.
        let bodyBoxes = targets
        for box in bodyBoxes {
            guard let validity = box.uidValidity else { continue }
            let within: Int?
            switch offline.mode {
            case .recent:
                guard offline.recentMessageLimit > 0 else { continue }
                within = offline.recentMessageLimit
            case .selectedFolders, .allHistory:
                // The SQL query remains bounded by one body batch, but it must not stop at an
                // arbitrary newest-N window or an all-history account will stall forever.
                within = nil
            }
            let rows = try await store.missingBodies(in: box.rowID, within: within, limit: max(policy.bodyBatch, 1), maxSize: Int64.max, requireRaw: offline.downloadAttachments, requireIndex: offline.indexBodies)
            if !rows.isEmpty {
                try await fetchBodies(rows, in: box, validity: validity, client: syncClient, storeRaw: offline.downloadAttachments, indexText: offline.indexBodies)
                more = true
                break
            }
        }
        return more
    }

    /// Replays only pending read/flag/move actions after a successful server pass. Every action
    /// is checked against the account, mailbox name, UIDVALIDITY, UID, and optional Message-ID.
    /// A move is durably moved to review before any network validation, then removed only after
    /// the server move and local removal both complete. This survives a crash at an uncertain
    /// point without replaying the move automatically.
    func replayOfflineActions() async {
        let actions: [MailOfflineAction]
        do {
            actions = try await store.offlineActions(accountID: account.id, states: [.pending])
        } catch {
            notice(account.id, "Queued mail changes could not be read: " + error.localizedDescription)
            return
        }
        for action in actions {
            guard !Task.isCancelled else { return }
            var working = action
            working.attempts += 1
            working.updatedAt = Date()

            if action.kind == .move || action.kind == .archive {
                working.state = .review
                working.lastError = "Move checkpoint saved. Check both folders before retrying if the connection stops."
            }
            guard await persistOfflineAction(working) else { return }

            let source: (location: NativeMailStore.Location, box: NativeMailStore.Mailbox)
            do {
                source = try await validateOfflineSource(action)
            } catch {
                if action.kind == .move || action.kind == .archive {
                    await markOfflineReview(working, text: error.localizedDescription)
                } else if isTransientOffline(error) {
                    working.state = .pending
                    working.lastError = error.localizedDescription
                    working.updatedAt = Date()
                    guard await persistOfflineAction(working) else { return }
                } else if let mailError = error as? MailError {
                    if case .signInFailed = mailError {
                        working.state = .failed
                        working.lastError = error.localizedDescription
                        working.updatedAt = Date()
                        guard await persistOfflineAction(working) else { return }
                    } else {
                        await markOfflineReview(working, text: error.localizedDescription)
                    }
                } else {
                    working.state = .failed
                    working.lastError = error.localizedDescription
                    working.updatedAt = Date()
                    guard await persistOfflineAction(working) else { return }
                }
                continue
            }
            do {
                switch action.kind {
                case .read, .flag:
                    guard let desired = action.desiredValue else { throw MailError.notFound("This queued mail change has no value.") }
                    let flag = action.kind == .read ? "\\Seen" : "\\Flagged"
                    try await setFlag(flag, desired, at: source.location)
                    if action.kind == .read { try await store.setLocal(source.location.rowID, read: desired) }
                    else { try await store.setLocal(source.location.rowID, flagged: desired) }
                    try await store.removeOfflineAction(action.id)
                case .archive, .move:
                    guard let destinationName = action.destinationMailboxName,
                          let destination = mailboxes.first(where: { $0.name == destinationName }) else {
                        throw MailError.notFound("The queued destination folder is no longer available.")
                    }
                    let destinationInfo = try await actionClient.select(destination.name)
                    if let destinationValidity = action.destinationUIDValidity,
                       destinationValidity != destinationInfo.uidValidity {
                        throw MailError.uidValidityChanged(mailbox: destination.name)
                    }
                    try await actionClient.move(uids: IMAPSequenceSet([action.uid]), to: destination.name,
                                                in: source.location.mailbox.name, validity: action.uidValidity)
                    try await store.adjustServerCounts(destination.rowID, total: 1, unread: source.location.read ? 0 : 1)
                    try await store.remove(uids: [action.uid], from: source.location.mailbox.rowID)
                    await signal.post(MailSyncRequest(mailboxes: [destination.rowID]))
                    try await store.removeOfflineAction(action.id)
                }
            } catch MailError.uidValidityChanged(let mailbox) {
                await markOfflineReview(working, text: "The server changed " + mailbox + "'s identity. Open the message and choose the action again.")
            } catch {
                if action.kind == .move || action.kind == .archive {
                    await markOfflineReview(working, text: "The move could not be confirmed. Check both folders before trying again.")
                } else if isTransientOffline(error) {
                    working.state = .pending; working.lastError = error.localizedDescription; working.updatedAt = Date()
                    guard await persistOfflineAction(working) else { return }
                } else {
                    working.state = .failed; working.lastError = error.localizedDescription; working.updatedAt = Date()
                    guard await persistOfflineAction(working) else { return }
                }
            }
        }
    }

    private func isTransientOffline(_ error: Error) -> Bool {
        if let mailError = error as? MailError, case .signInFailed = mailError { return false }
        return MailIOPolicy.isOffline || (error as? MailError)?.canQueueOffline == true || error is MailTransportError
    }

    private func persistOfflineAction(_ action: MailOfflineAction) async -> Bool {
        do {
            try await store.updateOfflineAction(action)
            return true
        } catch {
            notice(account.id, "Queued mail change could not be saved: " + error.localizedDescription)
            return false
        }
    }

    private func markOfflineReview(_ action: MailOfflineAction, text: String) async {
        var review = action; review.state = .review; review.lastError = text; review.updatedAt = Date()
        _ = await persistOfflineAction(review)
    }

    private func validateOfflineSource(_ action: MailOfflineAction) async throws -> (location: NativeMailStore.Location, box: NativeMailStore.Mailbox) {
        guard action.accountID == account.id,
              let box = mailboxes.first(where: { $0.name == action.mailboxName }) else {
            throw MailError.notFound("The queued message's account or folder is no longer available.")
        }
        let info = try await actionClient.select(box.name)
        guard info.uidValidity == action.uidValidity else { throw MailError.uidValidityChanged(mailbox: box.name) }
        guard let rowID = try await store.rowID(uid: action.uid, in: box.rowID),
              let location = try await store.location(of: rowID), location.mailbox.account == account.id,
              location.mailbox.name == box.name, location.mailbox.uidValidity == action.uidValidity,
              location.uid == action.uid else {
            throw MailError.notFound("The queued message is no longer cached in that folder.")
        }
        let headers = try await actionClient.fetch(uids: IMAPSequenceSet([action.uid]),
                                                   items: "(UID BODY.PEEK[HEADER.FIELDS (Message-ID)])",
                                                   in: box.name, validity: action.uidValidity)
        guard headers.count == 1, headers[0].uid == action.uid else {
            throw MailError.notFound("The server did not return the queued message identity.")
        }
        if let expected = action.messageID {
            let actual = SyncedMessage(fetch: headers[0])?.messageID
            guard actual == expected else { throw MailError.notFound("The queued message identity no longer matches.") }
        }
        return (location, box)
    }
}
