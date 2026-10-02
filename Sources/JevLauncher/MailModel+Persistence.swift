import Foundation
import LauncherCore

extension MailModel {
    func persistComposition() {
        guard let draftStore else { return }
        persistenceWork?.cancel()
        persistenceWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            do { try self.saveComposition(to: draftStore) }
            catch { self.persistenceProblem = "Your mail drafts could not be saved: " + error.localizedDescription; self.banner = self.persistenceProblem }
        }
    }

    func saveComposition(to store: MailDraftStore? = nil) throws {
        persistenceWork?.cancel(); persistenceWork = nil
        guard let store = store ?? draftStore else { return }
        // A failed load must not overwrite the unread file with a new empty snapshot.
        if let persistenceProblem { throw LauncherError(persistenceProblem) }
        try store.save(.init(active: draft, unsent: unsent, deliveries: deliveries))
    }

    func recordDelivery(_ draft: Draft, state: MailDelivery.State, note: String? = nil) {
        if let index = deliveries.firstIndex(where: { $0.id == draft.id }) {
            deliveries[index].state = state; deliveries[index].note = note
            deliveries[index].draft = [.sent, .undone].contains(state) ? nil : draft
        } else {
            deliveries.append(.init(id: draft.id, draft: draft, subject: draft.subject, recipient: draft.to,
                                    date: Date(), state: state, note: note))
        }
        let completed = deliveries.filter { [.sent, .undone].contains($0.state) }
        if completed.count > 30 {
            let old = Set(completed.prefix(completed.count - 30).map(\.id))
            deliveries.removeAll { old.contains($0.id) }
        }
    }

    func restoreDelivery(_ delivery: MailDelivery, allowResend: Bool = false) {
        guard var recovered = delivery.draft else { return }
        if allowResend { recovered.uncertainSend = false }
        guard startDraft(recovered) else { return }
        unsent.removeAll { $0.id == recovered.id }
        if allowResend { recordDelivery(recovered, state: .failed, note: "You confirmed this message was not sent.") }
        showsOutbox = false
    }
}
