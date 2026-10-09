import Foundation

extension MailModel {
    func restoreScheduled(_ entry: MailScheduleEntry) {
        var recovered = entry.draft
        recovered.uncertainSend = entry.requiresSentCheck
        if recovered.uncertainSend {
            recordDelivery(recovered, state: .uncertain, note: "Scheduled delivery was interrupted. Check Sent before resending.")
        }
        if !startDraft(recovered), !unsent.contains(where: { $0.id == recovered.id }) {
            unsent.append(.init(draft: recovered, reason: "Returned from Scheduled."))
        }
        Task { do { try await saveCompositionAsync() } catch { banner = error.localizedDescription } }
    }
    /// The schedule is durable before this transfer. The send guard also checks its persisted ID,
    /// so a crash between the two saves cannot leave a second sendable local copy.
    func didSchedule(_ entry: MailScheduleEntry) {
        guard draft?.id == entry.draft.id else { return }
        draft = nil
        unsent.removeAll { $0.id == entry.draft.id }
        banner = "Scheduled on this Mac. Jevcast must be running and this Mac awake."
        Task { do { try await saveCompositionAsync() } catch { banner = error.localizedDescription } }
    }
}
