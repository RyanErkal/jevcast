import Foundation
import LauncherCore

/// One archive, delete, or move that ⌘Z can put back: what it did and which messages it moved.
struct MailUndoableChange: Identifiable, Equatable {
    let id: UUID
    let operation: MailBulkOperation
    let title: String
    /// The messages whose change the server took. Only these are moved back.
    var moved: [MailBulkSnapshot] = []
}

extension MailModel {
    /// How long the Undo note stays. After it, the change stands.
    static let undoSeconds: UInt64 = 8

    /// Runs a change that moves messages out of the list, and keeps what Undo needs to move them back.
    func undoably(_ operation: MailBulkOperation, title: String, _ items: [(MailSummary, MailMailbox)], name: String? = nil,
                  _ action: @escaping (MailSummary, MailMailbox) async throws -> Void) {
        let change = MailUndoableChange(id: UUID(), operation: operation, title: title)
        banner = nil
        lastChange = change
        let label = name ?? title.lowercased()
        for (message, box) in items {
            let known = conversationHeaders[message.rowID]?.messageID
            perform(label, message: message, removes: true) { [weak self] in
                // Read before the move: afterwards the server gives the message a new number.
                let messageID = await MailActions.messageID(message, in: box) ?? known
                try await action(message, box)
                guard let self, self.lastChange?.id == change.id else { return }
                self.lastChange?.moved.append(MailBulkSnapshot(message: message, sourceMailboxID: box.rowID, accountID: box.accountID,
                                                               expectedMessageID: messageID))
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.undoSeconds * 1_000_000_000)
            if self?.lastChange?.id == change.id { self?.lastChange = nil }
        }
    }

    /// Puts the last change back. It waits for the change itself to finish first, so it never
    /// races it, and it moves only the messages that the change moved.
    func undoLastChange() {
        guard let change = lastChange, !bulkBusy else { return }
        lastChange = nil
        Task { @MainActor [weak self] in
            await self?.waitForActions()
            guard let self else { return }
            // The change may have failed; then its own note already says so and nothing moved.
            guard !change.moved.isEmpty else { return }
            self.bulkResult = MailBulkResult(operation: change.operation, reviewed: change.moved, succeeded: change.moved, undoable: change.moved)
            self.undoBulk()
        }
    }
}
