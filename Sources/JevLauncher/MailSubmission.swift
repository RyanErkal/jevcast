import Foundation
import LauncherCore

enum MailSubmission: Sendable {
    case serverAccepted(MailSendReceipt?)
    case appleMailQueued
}

extension MailModel {
    func recordSubmission(_ draft: Draft, _ submitted: MailSubmission) {
        switch submitted {
        case .appleMailQueued:
            recordDelivery(draft, state: .appleMailQueued, note: "Apple Mail has this message in its Outbox. Delivery is managed by Apple Mail.")
            if let index = deliveries.firstIndex(where: { $0.id == draft.id }) { deliveries[index].receipt = nil }
            banner = "Queued in Apple Mail."
        case .serverAccepted(let receipt):
            let state: MailDelivery.State = receipt?.sentCopy == .pending ? .sentCopyPending : .sent
            recordDelivery(draft, state: state, note: receipt?.note)
            if let index = deliveries.firstIndex(where: { $0.id == draft.id }) { deliveries[index].receipt = receipt }
            banner = state == .sentCopyPending ? "Sent. The copy in Sent needs attention." : "Sent."
        }
        if let index = deliveries.firstIndex(where: { $0.id == draft.id }) {
            let references = [draft.serverDraftReference, draft.previousServerDraftReference].compactMap { $0 }
            deliveries[index].serverDraftCleanupReferences = references.isEmpty ? nil : references
        }
    }

    func repairSentCopy(_ item: MailDelivery) {
        guard repairingSentCopies.insert(item.id).inserted else { return }
        guard let receipt = item.receipt, receipt.sentCopy == .pending, let engine = NativeMailCenter.activeEngine else {
            repairingSentCopies.remove(item.id)
            banner = "Select this message's Jevcast mail source before repairing its Sent copy."; return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.repairingSentCopies.remove(item.id) }
            do {
                let repaired = try await engine.repairSentCopy(receipt)
                guard MailBackend.current == .jevcast, let index = self.deliveries.firstIndex(where: { $0.id == item.id }) else { return }
                self.deliveries[index].receipt = repaired
                self.deliveries[index].state = .sent
                self.deliveries[index].note = nil
                try await self.saveCompositionAsync()
                self.banner = "Saved the Sent copy. The message was not sent again."
            } catch { self.banner = "The Sent copy could not be repaired: " + error.localizedDescription }
        }
    }
}
