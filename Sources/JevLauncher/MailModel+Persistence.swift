import Foundation
import LauncherCore

extension MailModel {
    /// Schedules one coalesced draft save. The value snapshot is captured on MainActor before the
    /// debounce sleep, so a later edit cannot be accidentally written by an older task.
    func persistComposition() {
        guard let store = draftStore else { return }
        let snapshot = compositionSnapshot()
        persistenceWork?.cancel()
        persistenceWork = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                try await store.saveAsync(snapshot)
                // A canceled autosave may have been admitted to the writer before a forced send
                // checkpoint. Its write remains ordered, but it must not report a late error.
                guard !Task.isCancelled else { return }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.persistenceProblem = "Your mail drafts could not be saved: " + error.localizedDescription
                self.banner = self.persistenceProblem
            }
        }
    }

    /// Saves the current composition state after canceling a pending debounce. Capture happens
    /// before the first await, which prevents a concurrent edit from changing a forced send-state
    /// checkpoint. `MailDraftStore` orders this write after any already-admitted autosave.
    func saveCompositionAsync(to store: MailDraftStore? = nil) async throws {
        persistenceWork?.cancel()
        persistenceWork = nil
        guard let store = store ?? draftStore else { return }
        // A failed load must not overwrite the unread file with a new empty snapshot.
        if let persistenceProblem { throw LauncherError(persistenceProblem) }
        let snapshot = compositionSnapshot()
        try await store.saveAsync(snapshot)
    }

    /// Synchronous save retained for deterministic startup and existing non-async callers. New
    /// production send/close paths should use `saveCompositionAsync`.
    func saveComposition(to store: MailDraftStore? = nil) throws {
        persistenceWork?.cancel(); persistenceWork = nil
        guard let store = store ?? draftStore else { return }
        // A failed load must not overwrite the unread file with a new empty snapshot.
        if let persistenceProblem { throw LauncherError(persistenceProblem) }
        try store.save(compositionSnapshot())
    }

    private func compositionSnapshot() -> MailDraftStore.Snapshot {
        .init(active: draft, unsent: unsent, deliveries: deliveries)
    }

    func recordDelivery(_ draft: Draft, state: MailDelivery.State, note: String? = nil) {
        if let index = deliveries.firstIndex(where: { $0.id == draft.id }) {
            deliveries[index].state = state; deliveries[index].note = note
            deliveries[index].draft = [.sent, .sentCopyPending, .appleMailQueued, .undone].contains(state) ? nil : draft
        } else {
            deliveries.append(.init(id: draft.id, draft: [.sent, .sentCopyPending, .appleMailQueued, .undone].contains(state) ? nil : draft, subject: draft.subject, recipient: draft.to,
                                    date: Date(), state: state, note: note))
        }
        // An accepted delivery may be the only durable cleanup pointer after a journal failure.
        // Keep it until every exact server-draft reference has been cleared.
        let completed = deliveries.filter {
            [.sent, .undone].contains($0.state) && ($0.serverDraftCleanupReferences?.isEmpty ?? true)
        }
        if completed.count > 30 {
            let old = Set(completed.prefix(completed.count - 30).map(\.id))
            deliveries.removeAll { old.contains($0.id) }
        }
    }

    func restoreDelivery(_ delivery: MailDelivery, allowResend: Bool = false) {
        guard [.failed, .uncertain].contains(delivery.state), delivery.state != .uncertain || allowResend,
              var recovered = delivery.draft else { return }
        if allowResend { recovered.uncertainSend = false }
        guard startDraft(recovered) else { return }
        unsent.removeAll { $0.id == recovered.id }
        if allowResend { recordDelivery(recovered, state: .failed, note: "You confirmed this message was not sent.") }
        showsOutbox = false
    }
}
