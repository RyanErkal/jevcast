import Foundation
import Combine
import LauncherCore

/// Serializes local composition checkpoints and exact server-Drafts mutations. Debounce tasks may
/// be cancelled while typing; once a server operation is admitted to `serial`, it is never
/// cancelled by a later edit.
@MainActor
final class MailServerDraftCoordinator: ObservableObject {
    typealias SaveOperation = @Sendable (String, Data, String, MailServerDraftReference?) async throws -> MailServerDraftReference
    typealias RemoveOperation = @Sendable (MailServerDraftReference) async throws -> Void

    private final class Slot {
        let id: UUID
        var generation = 0
        var accountID: String?
        var reference: MailServerDraftReference?
        var previous: MailServerDraftReference?
        private(set) var blockedReason: String?
        private(set) var blockKind: MailModel.Draft.ServerDraftBlockKind?
        var uncertain = false
        var stopped = false
        var lastFields: MailModel.Draft.Fields?
        var debounce: Task<Void, Never>?
        var serial: Task<Void, Never>?
        var cleanupReferences: [MailServerDraftReference] = []

        init(_ draft: MailModel.Draft) {
            id = draft.id
            accountID = draft.fromAccountID
            reference = draft.serverDraftReference
            previous = draft.previousServerDraftReference
            blockedReason = draft.serverDraftBlockedReason
            blockKind = blockedReason == nil ? nil : draft.serverDraftBlockKind
            uncertain = draft.serverDraftAcknowledgementUncertain == true
            // Importing a server Drafts row is read-only until a user edit changes its fields.
            lastFields = draft.serverDraftImported == true ? draft.fields : nil
        }

        /// Sets or clears the block. Only a caller that knows the exact cause may name a kind, so
        /// every other block, including one replacing a refused sign-in, cannot be retried.
        func block(_ reason: String?, kind: MailModel.Draft.ServerDraftBlockKind? = nil) {
            blockedReason = reason
            blockKind = reason == nil ? nil : kind
        }

        /// A refused sign-in happens before APPEND or removal, so it leaves no server state to
        /// review. Any uncertain, partial, or cleanup reference keeps the draft blocked.
        var canRetrySignIn: Bool {
            blockedReason != nil && blockKind == .signInRefused && !uncertain
                && previous == nil && cleanupReferences.isEmpty
        }

        var references: [MailServerDraftReference] {
            var result: [MailServerDraftReference] = []
            for value in [reference, previous].compactMap({ $0 }) + cleanupReferences where !result.contains(value) { result.append(value) }
            return result
        }
    }

    private unowned let model: MailModel
    private let injectedSave: SaveOperation?
    private let injectedRemove: RemoveOperation?
    private let cleanupStore: MailServerDraftCleanupStore?
    private let debounceNanoseconds: UInt64
    private var slots: [UUID: Slot] = [:]
    @Published private(set) var pendingCleanupRecords: [MailServerDraftCleanupRecord] = []
    /// Drafts with an explicit server-save retry in progress, for the composer's status.
    @Published private(set) var retryingDraftIDs: Set<UUID> = []
    private var cleanupReloadTask: Task<Void, Never>?

    /// Production coordinator. It does no file or network work until `changed`, `prepareForSend`,
    /// `completedSend`, or `discard` is called and the current source is a live Jevcast account.
    convenience init(model: MailModel) {
        self.init(model: model, save: nil, remove: nil, cleanupStore: .standard)
    }

    /// Injected save/remove operations keep fixture tests completely off real accounts and the
    /// network. The cleanup store is injectable for the same reason.
    init(model: MailModel, save: SaveOperation? = nil, remove: RemoveOperation? = nil,
         cleanupStore: MailServerDraftCleanupStore? = nil, debounceNanoseconds: UInt64 = 350_000_000) {
        self.model = model
        injectedSave = save
        injectedRemove = remove
        self.cleanupStore = cleanupStore
        self.debounceNanoseconds = debounceNanoseconds
        if cleanupStore != nil { reloadCleanup() }
    }

    /// Called after the local model schedules its composition persistence. A fake API may be used
    /// with fixtures even when the process is offline; without one, an offline or Apple-Mail model
    /// performs zero server-draft I/O.
    func changed(_ draft: MailModel.Draft?) {
        guard let draft, hasServerAPI(for: draft) else { return }
        guard draft.hasContent else { return }
        let slot = slot(for: draft)
        if slot.stopped {
            // A known failed send or an Undo restores the same draft ID. It is safe to resume
            // autosave for that explicit recovery state. Accepted/discarded IDs never resume.
            if deliveryAllowsRecovery(draft.id), !slot.uncertain, slot.blockedReason == nil {
                slot.stopped = false
                slot.lastFields = nil
            } else {
                preserveBlockedState(slot, on: draft)
                return
            }
        }
        if slot.blockedReason != nil || slot.uncertain {
            preserveBlockedState(slot, on: draft)
            return
        }

        if let oldAccount = slot.accountID, let newAccount = draft.fromAccountID,
           oldAccount != newAccount, !slot.references.isEmpty {
            let reason = "This draft was switched to another account. Discard it and reopen it before saving a new server copy."
            slot.block(reason)
            applyState(slot, to: draft, reason: reason, uncertain: false)
            model.banner = reason
            return
        }
        if slot.references.isEmpty { slot.accountID = draft.fromAccountID }
        slot.accountID = slot.accountID ?? draft.fromAccountID

        // A state-only update from this coordinator does not constitute a new content edit.
        if slot.lastFields == draft.fields, slot.reference == draft.serverDraftReference,
           slot.previous == draft.previousServerDraftReference { return }

        slot.generation += 1
        let generation = slot.generation
        slot.debounce?.cancel()
        let retainedModel = model
        slot.debounce = Task { @MainActor [weak self, weak slot] in
            defer { withExtendedLifetime(retainedModel) {} }
            do { try await Task.sleep(nanoseconds: self?.debounceNanoseconds ?? 0) }
            catch { return }
            guard let self, let slot, !Task.isCancelled, !slot.stopped,
                  slot.generation == generation, slot.blockedReason == nil, !slot.uncertain else { return }
            // The value captured after debounce is the newest value for this ID. It is safe to
            // enqueue even if another edit arrives while the admitted operation is running.
            guard let current = retainedModel.serverDraft(for: draft.id), current.id == draft.id else { return }
            self.enqueue(slot) { [weak self, weak slot] in
                guard let self, let slot else { return }
                await self.autosave(current, slot: slot)
            }
        }
    }

    /// True when the open draft's only block is a refused sign-in and a server API is available.
    /// Uncertain, partial, account-switch, cleanup, and older unclassified blocks are never eligible.
    func canRetryServerSave(_ draft: MailModel.Draft) -> Bool {
        hasServerAPI(for: draft) && blockAllowsRetry(draft)
    }

    /// The block alone allows a retry, whether or not a server API is available right now.
    func blockAllowsRetry(_ draft: MailModel.Draft) -> Bool {
        (slots[draft.id] ?? Slot(draft)).canRetrySignIn
    }

    /// Explicit user action after the account's sign-in is fixed. It makes one server Drafts save
    /// of the latest local draft, replacing only the exact reference it already owns. It never
    /// calls SMTP or resumes a send. A refused sign-in blocks again; any other problem keeps or
    /// replaces the block exactly as autosave would. Returns true when the block was cleared.
    @discardableResult
    func retryServerSave(_ draft: MailModel.Draft) async -> Bool {
        let id = draft.id
        guard model.draft?.id == id, model.pendingSend?.id != id else {
            model.banner = "Open this draft to save it to the server again."
            return false
        }
        guard hasServerAPI(for: draft) else {
            model.banner = "Select Jevcast accounts as the mail source before saving this server draft."
            return false
        }
        guard !retryingDraftIDs.contains(id) else { return false }
        let slot = slot(for: draft)
        guard slot.canRetrySignIn else {
            model.banner = "Jevcast cannot retry this server draft. " + (slot.blockedReason ?? "Nothing is blocked.")
            return false
        }
        if slot.stopped, !deliveryAllowsRecovery(id) {
            model.banner = "This draft is being sent or was closed. Nothing was saved."
            return false
        }

        retryingDraftIDs.insert(id)
        defer { retryingDraftIDs.remove(id) }
        let cleared: Bool = await withCheckedContinuation { continuation in
            enqueue(slot) { [weak self, weak slot] in
                guard let self, let slot else { continuation.resume(returning: false); return }
                continuation.resume(returning: await self.retry(id: id, slot: slot))
            }
        }
        // Edits typed while the retry ran were not part of its save. Normal autosave takes them.
        if cleared, let current = model.draft, current.id == id { changed(current) }
        return cleared
    }

    /// Runs inside `serial`, so earlier admitted saves and later sends or discards stay ordered.
    private func retry(id: UUID, slot: Slot) async -> Bool {
        // An earlier admitted operation can have replaced the sign-in block or closed the draft.
        guard slot.canRetrySignIn, let current = model.serverDraft(for: id) else { return false }
        guard hasServerAPI(for: current) else {
            model.banner = "The mail source changed. The server draft was not saved."
            return false
        }
        if let oldAccount = slot.accountID, let newAccount = current.fromAccountID,
           oldAccount != newAccount, !slot.references.isEmpty {
            let reason = "This draft was switched to another account. Discard it and reopen it before saving a new server copy."
            slot.block(reason)
            applyState(slot, to: current, reason: reason, uncertain: false)
            try? await model.saveCompositionAsync()
            model.banner = reason
            return false
        }
        if slot.references.isEmpty { slot.accountID = current.fromAccountID }

        do {
            try await model.saveCompositionAsync()
            try await save(current, slot: slot)
        } catch let error as MailServerDraftRenderError {
            model.banner = error.localizedDescription
        } catch {
            await handleSaveFailure(error, draft: current, slot: slot)
        }
        guard slot.blockedReason == nil, !slot.uncertain else {
            // A failure that did not replace the sign-in block (a dropped connection, say) leaves
            // it retryable. Keep the stored draft in step with it.
            if slot.canRetrySignIn, let latest = model.serverDraft(for: id) {
                preserveBlockedState(slot, on: latest)
                try? await model.saveCompositionAsync()
            }
            return false
        }
        model.banner = "The draft was saved to the server Drafts folder. Autosave is on again."
        return true
    }

    private func deliveryAllowsRecovery(_ id: UUID) -> Bool {
        model.deliveries.first(where: { $0.id == id }).map { $0.state == .failed || $0.state == .undone } ?? false
    }

    /// Stops new autosaves, waits behind all already-admitted work, and returns the latest local
    /// draft with its safe server references. This does not call SMTP or resume any send.
    func prepareForSend(_ draft: MailModel.Draft) async throws -> MailModel.Draft {
        let slot = slot(for: draft)
        slot.stopped = true
        slot.debounce?.cancel(); slot.debounce = nil
        return try await withCheckedThrowingContinuation { continuation in
            enqueue(slot) { [weak self, weak slot] in
                guard let self, let slot else {
                    continuation.resume(throwing: CancellationError()); return
                }
                do {
                    try await self.model.saveCompositionAsync()
                    if let reason = slot.blockedReason { throw LauncherError(reason) }
                    if slot.uncertain { throw LauncherError("Review the server Drafts folder before sending this message again.") }
                    var latest = self.model.serverDraft(for: draft.id) ?? draft
                    guard latest.id == draft.id else { throw LauncherError("This draft is no longer open.") }

                    latest.serverDraftReference = slot.reference
                    latest.previousServerDraftReference = slot.previous
                    latest.serverDraftBlockedReason = slot.blockedReason
                    latest.serverDraftBlockKind = slot.blockKind
                    latest.serverDraftAcknowledgementUncertain = slot.uncertain ? true : nil
                    try await self.model.saveCompositionAsync()
                    continuation.resume(returning: latest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Cleans up exact owned Drafts references after root has recorded server acceptance or Apple
    /// Mail queueing. Cleanup failures are reported and journaled, but never change acceptance.
    func completedSend(_ draft: MailModel.Draft) async {
        guard draft.backend == MailBackend.jevcast.rawValue else { return }
        // A Drafts row imported from another device is not Jevcast-owned. Sending its contents is
        // explicit, but cleanup must not delete the other device's copy without an ownership proof.
        if draft.serverDraftImported == true { return }
        let slot = slot(for: draft)
        slot.stopped = true
        slot.debounce?.cancel(); slot.debounce = nil
        if slot.reference == nil { slot.reference = draft.serverDraftReference }
        if slot.previous == nil { slot.previous = draft.previousServerDraftReference }
        for reference in model.serverDraftCleanupReferences(for: draft.id) where !slot.cleanupReferences.contains(reference) {
            slot.cleanupReferences.append(reference)
        }
        let id = draft.id
        await withCheckedContinuation { continuation in
            enqueue(slot) { [weak self, weak slot] in
                guard let self, let slot else { continuation.resume(); return }
                await self.cleanup(id: id, slot: slot, accepted: true)
                continuation.resume()
            }
        }
    }

    /// Explicit discard path. The local checkpoint is admitted before any exact server removal;
    /// ambiguous failures stay in the cleanup journal and are never retried automatically.
    func discard(_ draft: MailModel.Draft) {
        // Opening a cross-device server draft never grants delete authority. An edited copy becomes
        // owned only after the coordinator successfully replaces the exact reference.
        if draft.serverDraftImported == true { return }
        let slot = slot(for: draft)
        slot.stopped = true
        slot.debounce?.cancel(); slot.debounce = nil
        if slot.reference == nil { slot.reference = draft.serverDraftReference }
        if slot.previous == nil { slot.previous = draft.previousServerDraftReference }
        enqueue(slot) { [weak self, weak slot] in
            guard let self, let slot else { return }
            await self.cleanup(id: draft.id, slot: slot, accepted: false)
        }
    }

    /// Reloads durable cleanup pointers for UI. This is read-only and never starts a removal.
    func reloadCleanup() {
        cleanupReloadTask?.cancel()
        let retainedModel = model
        cleanupReloadTask = Task { @MainActor [weak self] in
            defer { withExtendedLifetime(retainedModel) {} }
            await self?.reloadCleanupNow()
        }
    }

    /// The async form is useful to explicit recovery UI and tests that need to wait until the
    /// journal has been read. It still only loads and merges pointers. It never removes a UID.
    func reloadCleanupAsync() async {
        await reloadCleanupNow()
    }

    /// Explicit user action for one cleanup pointer. There is no startup retry or automatic
    /// reconciliation, and this method never sends or restores an accepted message.
    func retryServerDraftCleanup(_ record: MailServerDraftCleanupRecord) async -> Bool {
        guard cleanupStore != nil else { model.banner = "Server-draft cleanup storage is unavailable."; return false }
        var draft = MailModel.Draft(id: record.draftID)
        draft.backend = MailBackend.jevcast.rawValue
        let slot = slots[record.draftID] ?? Slot(draft)
        slots[record.draftID] = slot
        slot.stopped = true
        slot.cleanupReferences = record.references
        slot.reference = record.references.first
        slot.previous = record.references.dropFirst().first
        await withCheckedContinuation { continuation in
            enqueue(slot) { [weak self, weak slot] in
                guard let self, let slot else { continuation.resume(); return }
                await self.cleanup(id: record.draftID, slot: slot, accepted: record.accepted)
                continuation.resume()
            }
        }
        await reloadCleanupNow()
        return !pendingCleanupRecords.contains(where: { $0.draftID == record.draftID })
    }

    private func reloadCleanupNow() async {
        let retainedModel = model
        let deliveryRecords = deliveryCleanupRecords()
        guard let cleanupStore else {
            pendingCleanupRecords = deliveryRecords
            return
        }

        do {
            let read = Task.detached(priority: .utility) { () throws -> [MailServerDraftCleanupRecord] in
                try cleanupStore.load()
            }
            let journal = try await read.value
            guard !Task.isCancelled else { return }

            var merged = journal
            var changedRecords: [MailServerDraftCleanupRecord] = []
            for candidate in deliveryRecords {
                if let index = merged.firstIndex(where: { $0.draftID == candidate.draftID }) {
                    let current = merged[index]
                    let references = uniqueReferences(current.references + candidate.references)
                    let mergedRecord = MailServerDraftCleanupRecord(
                        draftID: current.draftID,
                        accepted: current.accepted || candidate.accepted,
                        references: references,
                        reason: current.reason.isEmpty ? candidate.reason : current.reason,
                        createdAt: current.createdAt
                    )
                    if mergedRecord != current {
                        merged[index] = mergedRecord
                        changedRecords.append(mergedRecord)
                    }
                } else {
                    merged.append(candidate)
                    changedRecords.append(candidate)
                }
            }

            pendingCleanupRecords = merged
            // The delivery pointer can be the only durable record after a crash between the
            // composition checkpoint and journal creation. Persist the union, but do not start
            // cleanup here. Each save is ordered by the store's private serial queue.
            for record in changedRecords {
                do { try await cleanupStore.saveAsync(record) }
                catch {
                    retainedModel.banner = "Server-draft cleanup records could not be saved: " + error.localizedDescription
                    return
                }
            }
        } catch {
            // Never replace an unreadable journal. Delivery pointers remain visible so the user
            // can recover the exact accepted references after fixing the storage problem.
            pendingCleanupRecords = deliveryRecords
            retainedModel.banner = "Server-draft cleanup records could not be loaded: " + error.localizedDescription
        }
    }

    private func deliveryCleanupRecords() -> [MailServerDraftCleanupRecord] {
        model.deliveries.compactMap { delivery in
            guard let references = delivery.serverDraftCleanupReferences, !references.isEmpty else { return nil }
            return MailServerDraftCleanupRecord(
                draftID: delivery.id,
                accepted: true,
                references: uniqueReferences(references),
                reason: "Accepted mail still has a server Drafts copy.",
                createdAt: delivery.date
            )
        }
    }

    private func uniqueReferences(_ references: [MailServerDraftReference]) -> [MailServerDraftReference] {
        var unique: [MailServerDraftReference] = []
        for reference in references where !unique.contains(reference) { unique.append(reference) }
        return unique
    }

    // MARK: Serial operations

    private func slot(for draft: MailModel.Draft) -> Slot {
        if let existing = slots[draft.id] {
            if existing.reference == nil { existing.reference = draft.serverDraftReference }
            if existing.previous == nil { existing.previous = draft.previousServerDraftReference }
            return existing
        }
        let new = Slot(draft); slots[draft.id] = new; return new
    }

    private func enqueue(_ slot: Slot, _ operation: @escaping @MainActor () async -> Void) {
        let previous = slot.serial
        let retainedModel = model
        let task = Task { @MainActor in
            defer { withExtendedLifetime(retainedModel) {} }
            await previous?.value
            await operation()
        }
        slot.serial = task
    }

    private func hasServerAPI(for draft: MailModel.Draft) -> Bool {
        if injectedSave != nil || injectedRemove != nil { return true }
        guard draft.backend == MailBackend.jevcast.rawValue, MailBackend.current == .jevcast else { return false }
        return !MailIOPolicy.isOffline && NativeMailCenter.activeEngine != nil
    }

    private func autosave(_ draft: MailModel.Draft, slot: Slot) async {
        // `stopped` only prevents new debounce admissions. This operation was already admitted
        // and must run before prepare/discard proceeds.
        guard slot.blockedReason == nil, !slot.uncertain else { return }
        do {
            try await model.saveCompositionAsync()
            try await save(draft, slot: slot)
        } catch let error as MailServerDraftRenderError {
            // A source without captured forward bytes can be retried after the source is captured;
            // do not make an otherwise usable local draft permanently blocked.
            model.banner = error.localizedDescription
        } catch {
            await handleSaveFailure(error, draft: draft, slot: slot)
        }
    }

    private func save(_ draft: MailModel.Draft, slot: Slot) async throws {
        guard hasServerAPI(for: draft) else { return }
        guard let accountID = draft.fromAccountID, !accountID.isEmpty else {
            throw LauncherError("Select a sending account before saving this server draft.")
        }
        if let anchored = slot.accountID, anchored != accountID, !slot.references.isEmpty {
            throw LauncherError("This draft's server copy belongs to another account. Discard it or select the original account.")
        }
        let sender = model.senders.first { $0.accountID == accountID && $0.address.caseInsensitiveCompare(draft.fromAddress ?? "") == .orderedSame }
        let raw = try MailServerDraftRenderer.render(draft, sender: sender)
        let replacing = slot.reference ?? draft.serverDraftReference
        let result = try await saveOnServer(accountID: accountID, raw: raw, messageID: draft.sendingMessageID,
                                            replacing: replacing)
        slot.accountID = accountID
        slot.reference = result
        slot.previous = nil
        slot.lastFields = draft.fields
        slot.block(nil)
        slot.uncertain = false

        // A stale result still must be checkpointed by ID. This updates only server metadata, not
        // typed fields, so a newer edit remains intact while the exact UID survives a crash.
        let found = model.updateServerDraftState(for: draft.id, reference: result)
        guard found else { return }
        do { try await model.saveCompositionAsync() }
        catch {
            let reason = "The server draft was saved, but its local reference could not be checkpointed: " + error.localizedDescription
            slot.block(reason)
            applyState(slot, to: draft, reason: reason, uncertain: false)
            model.banner = reason
            throw LauncherError(reason)
        }
    }

    private func saveOnServer(accountID: String, raw: Data, messageID: String,
                              replacing: MailServerDraftReference?) async throws -> MailServerDraftReference {
        if let injectedSave { return try await injectedSave(accountID, raw, messageID, replacing) }
        try MailIOPolicy.requireOnline()
        guard MailBackend.current == .jevcast, let engine = NativeMailCenter.activeEngine else {
            throw LauncherError("Select Jevcast accounts as the mail source before saving a server draft.")
        }
        guard await engine.accounts.contains(where: { $0.id == accountID }) else {
            throw LauncherError("The selected sending account is no longer available.")
        }
        return try await engine.saveServerDraft(from: accountID, raw: raw, messageID: messageID, replacing: replacing)
    }

    private func removeOnServer(_ reference: MailServerDraftReference) async throws {
        if let injectedRemove { try await injectedRemove(reference); return }
        try MailIOPolicy.requireOnline()
        guard MailBackend.current == .jevcast, let engine = NativeMailCenter.activeEngine else {
            throw LauncherError("Select Jevcast accounts as the mail source before removing a server draft.")
        }
        try await engine.removeServerDraft(reference)
    }

    // MARK: Failures and cleanup

    private func handleSaveFailure(_ error: Error, draft: MailModel.Draft, slot: Slot) async {
        let reason = error.localizedDescription
        switch error {
        case let problem as MailServerDraftError:
            switch problem {
            case let .acknowledgementUncertain(_, _, candidate, replacing):
                slot.reference = candidate ?? replacing ?? slot.reference
                slot.previous = replacing
                slot.block(reason)
                slot.uncertain = true
            case let .partialReplacement(previous, new, _):
                slot.reference = new; slot.previous = previous; slot.block(reason); slot.uncertain = false
            default:
                if !slot.references.isEmpty { slot.block(reason) }
            }
            applyState(slot, to: draft, reason: reason, uncertain: slot.uncertain)
            if slot.blockedReason != nil || slot.uncertain { try? await model.saveCompositionAsync() }
            model.banner = reason
        default:
            if let mailError = error as? MailError, case .signInFailed(_) = mailError {
                // A refused login is not a transient draft-rendering failure. Block this slot so
                // every later edit cannot repeatedly prompt or retry the same account. The sign-in
                // fails before APPEND, so the kind lets the user retry once they fix the account.
                slot.block(reason, kind: .signInRefused)
                applyState(slot, to: draft, reason: reason, uncertain: false)
                try? await model.saveCompositionAsync()
                model.banner = "Server-draft autosave stopped for this account: " + reason
                    + " After you fix the sign-in, choose Save to Drafts Again in the draft."
                return
            }
            model.banner = "The server draft could not be saved: " + reason
        }
    }

    private func applyState(_ slot: Slot, to draft: MailModel.Draft, reason: String?, uncertain: Bool) {
        // The kind travels only with the exact block it describes, never with another reason.
        let kind = reason != nil && reason == slot.blockedReason ? slot.blockKind : nil
        model.updateServerDraftState(for: draft.id, reference: slot.reference, previous: slot.previous,
                                     blockedReason: reason, blockKind: kind, acknowledgementUncertain: uncertain)
    }

    private func preserveBlockedState(_ slot: Slot, on draft: MailModel.Draft) {
        let blocked = slot.blockedReason
        let uncertain = slot.uncertain
        let same = draft.serverDraftReference == slot.reference
            && draft.previousServerDraftReference == slot.previous
            && draft.serverDraftBlockedReason == blocked
            && draft.serverDraftBlockKind == (blocked == nil ? nil : slot.blockKind)
            && draft.serverDraftAcknowledgementUncertain == (uncertain ? true : nil)
        if !same { applyState(slot, to: draft, reason: blocked, uncertain: uncertain) }
    }

    private func cleanup(id: UUID, slot: Slot, accepted: Bool) async {
        do { try await model.saveCompositionAsync() }
        catch {
            model.banner = "The cleanup result could not be checkpointed: " + error.localizedDescription
            return
        }
        var remaining = slot.references
        guard !remaining.isEmpty else { return }

        let initialReason = accepted ? "Accepted mail still has a server Drafts copy." : "Discarded draft still has a server Drafts copy."
        var record = MailServerDraftCleanupRecord(draftID: id, accepted: accepted, references: remaining,
                                                  reason: initialReason, createdAt: Date())
        do { try await cleanupStore?.saveAsync(record) }
        catch {
            let reason = "Server-draft cleanup could not be recorded: " + error.localizedDescription
            slot.block(reason)
            model.banner = reason
            return
        }

        var nativeDraft = model.serverDraft(for: id) ?? MailModel.Draft(id: id)
        // Cleanup references are Jevcast-owned by construction. Do not let a missing local
        // delivery body default this capability check to the currently selected Apple Mail
        // backend, which would incorrectly skip an available native engine.
        nativeDraft.backend = MailBackend.jevcast.rawValue
        guard hasServerAPI(for: nativeDraft) else {
            let reason = "\(initialReason) Select Jevcast accounts to remove it explicitly."
            record.reason = reason
            try? await cleanupStore?.updateAsync(record)
            slot.block(reason)
            applyState(slot, to: model.serverDraft(for: id) ?? MailModel.Draft(id: id), reason: reason, uncertain: true)
            model.banner = reason
            return
        }

        for reference in slot.references {
            do {
                try await removeOnServer(reference)
                remaining.removeAll { $0 == reference }
                record.references = remaining
                // The journal is advanced before composition.json. If the local checkpoint fails,
                // the durable journal still prevents an already-removed UID from being retried.
                if remaining.isEmpty { try? await cleanupStore?.removeAsync(draftID: id) }
                else { try? await cleanupStore?.updateAsync(record) }
                _ = model.updateServerDraftCleanupReferences(for: id, references: remaining)
                do { try await model.saveCompositionAsync() }
                catch {
                    let reason = "Server-draft cleanup succeeded for one UID, but the local cleanup checkpoint failed: " + error.localizedDescription
                    slot.block(reason)
                    model.banner = reason
                    return
                }
            } catch {
                let reason = "\(initialReason) " + error.localizedDescription
                record.reason = reason
                record.references = remaining
                try? await cleanupStore?.updateAsync(record)
                slot.reference = remaining.first
                slot.previous = remaining.dropFirst().first
                slot.block(reason)
                slot.uncertain = error is MailServerDraftError
                if model.serverDraft(for: id) != nil {
                    model.updateServerDraftState(for: id, reference: slot.reference, previous: slot.previous,
                                                 blockedReason: reason, acknowledgementUncertain: slot.uncertain)
                }
                model.banner = reason
                return
            }
        }
        slot.reference = nil; slot.previous = nil; slot.block(nil); slot.uncertain = false
        slot.cleanupReferences = []
        if model.updateServerDraftState(for: id, reference: nil) {
            try? await model.saveCompositionAsync()
        }
        reloadCleanup()
    }
}
