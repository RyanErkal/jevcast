import Foundation
import LauncherCore

extension MailModel {
    var bulkMoveDestinations: [MailMailbox] {
        let accounts = Set(selectedMessages.compactMap { actionBox($0)?.accountID })
        guard accounts.count == 1, let account = accounts.first else { return [] }
        let sources = Set(selectedMessages.compactMap { actionBox($0)?.rowID })
        return mailboxes.filter { $0.accountID == account && !sources.contains($0.rowID) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func moveMessage(_ rowID: Int64, to destination: MailMailbox) {
        guard messages.contains(where: { $0.rowID == rowID }) else { return }
        select(rowID, byUser: false)
        move(to: destination)
    }

    var selectedMessages: [MailSummary] {
        let selected = selectedMessageIDs
        return messages.filter { selected.contains($0.rowID) }
    }

    func setSelectedMessageIDs(_ ids: Set<Int64>) {
        let loaded = Set(messages.map(\.rowID))
        let next = ids.intersection(loaded)
        let added = next.subtracting(selectedMessageIDs)
        selectedMessageIDs = next
        if let first = added.first { selectionAnchorID = first }
        else if selectionAnchorID.map(next.contains) != true { selectionAnchorID = next.first }
        if let current = selectedID, next.contains(current) { return }
        select(next.sorted().last, byUser: false)
    }

    func clearSelection() { selectedMessageIDs.removeAll(); selectionAnchorID = nil }

    func toggleMessageSelection(_ rowID: Int64) {
        guard messages.contains(where: { $0.rowID == rowID }) else { return }
        var next = selectedMessageIDs
        if !next.insert(rowID).inserted { next.remove(rowID) }
        selectedMessageIDs = next
        selectionAnchorID = rowID
        select(rowID, byUser: false)
    }

    func selectMessageRange(to rowID: Int64) {
        guard let anchor = selectionAnchorID ?? selectedID,
              let start = messages.firstIndex(where: { $0.rowID == anchor }),
              let end = messages.firstIndex(where: { $0.rowID == rowID }) else {
            toggleMessageSelection(rowID)
            return
        }
        let range = start <= end ? start...end : end...start
        selectedMessageIDs.formUnion(messages[range].map(\.rowID))
        selectionAnchorID = rowID
        select(rowID, byUser: false)
    }

    /// Selects only rows currently loaded in the launcher. It never implies selecting future pages.
    func selectAllLoaded() {
        selectedMessageIDs = Set(messages.map(\.rowID))
        selectionAnchorID = messages.last?.rowID
        select(messages.last?.rowID, byUser: false)
    }

    func bulkSnapshots() -> [MailBulkSnapshot] {
        selectedMessages.compactMap { message in
            guard let source = actionBox(message) else { return nil }
            return MailBulkSnapshot(message: message, sourceMailboxID: source.rowID, accountID: source.accountID,
                                    expectedMessageID: conversationHeaders[message.rowID]?.messageID)
        }
    }

    /// Runs one operation over an immutable reviewed snapshot. No bulk operation passes the
    /// permanent-delete flag; Trash remains reversible by moving back to the reviewed folder.
    func bulk(_ operation: MailBulkOperation) {
        guard !bulkBusy else { return }
        let reviewed = bulkSnapshots()
        guard !reviewed.isEmpty else { banner = "Select one or more messages first."; return }
        bulkBusy = true
        bulkResult = nil
        let boxes = mailboxes
        Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded: [MailBulkSnapshot] = []
            var failures: [MailBulkFailure] = []
            for snapshot in reviewed {
                do {
                    try await self.verifyBulkSnapshot(snapshot, boxes: boxes)
                    try await self.performBulk(operation, snapshot: snapshot, boxes: boxes)
                    succeeded.append(snapshot)
                } catch {
                    failures.append(MailBulkFailure(snapshot: snapshot, reason: error.localizedDescription))
                }
            }
            let result = MailBulkResult(operation: operation, reviewed: reviewed, succeeded: succeeded,
                                        failures: failures, undoable: succeeded)
            self.bulkResult = result
            self.bulkBusy = false
            self.bulkUndoAvailable = !succeeded.isEmpty
            self.selectedMessageIDs.subtract(succeeded.map(\.message.rowID))
            if failures.isEmpty {
                self.banner = "Updated \(succeeded.count) message\(succeeded.count == 1 ? "" : "s")."
            } else {
                self.banner = "Updated \(succeeded.count) of \(reviewed.count) messages. \(failures.count) failed; nothing was retried automatically."
            }
            self.reload(keepSelection: true)
        }
    }

    private func verifyBulkSnapshot(_ snapshot: MailBulkSnapshot, boxes: [MailMailbox]) async throws {
        guard let box = boxes.first(where: { $0.rowID == snapshot.sourceMailboxID }), box.accountID == snapshot.accountID else {
            throw LauncherError("The reviewed mailbox is no longer available.")
        }
        guard let expected = snapshot.expectedMessageID else { return }
        guard case .ready(let root) = MailStore.status(),
              let detail = await Task.detached(priority: .userInitiated, operation: { MailStore.message(root: root, mailbox: box, rowID: snapshot.message.rowID) }).value,
              detail.header("Message-ID") == expected else {
            throw LauncherError("The reviewed message changed. Open it again before changing it.")
        }
    }

    private func performBulk(_ operation: MailBulkOperation, snapshot: MailBulkSnapshot, boxes: [MailMailbox]) async throws {
        guard let source = boxes.first(where: { $0.rowID == snapshot.sourceMailboxID }) else {
            throw LauncherError("The reviewed mailbox is no longer available.")
        }
        switch operation {
        case .markRead(let read): try await MailActions.setRead(read, snapshot.message, in: source)
        case .flag(let flagged): try await MailActions.setFlagged(flagged, snapshot.message, in: source)
        case .archive:
            guard let destination = MailMailbox.archive(for: source.accountID, in: boxes), destination.rowID != source.rowID else {
                throw LauncherError("This account has no Archive mailbox.")
            }
            try await MailActions.move(snapshot.message, from: source, to: destination)
        case .move(let mailboxID):
            guard let destination = boxes.first(where: { $0.rowID == mailboxID }), destination.accountID == source.accountID else {
                throw LauncherError("Messages move only within one account.")
            }
            try await MailActions.move(snapshot.message, from: source, to: destination)
        case .trash:
            try await MailActions.delete(snapshot.message, in: source, permanently: false)
        }
    }

    /// Reverses only successful actions from the exact previous result. A later source change
    /// causes an item to fail instead of overwriting newer user work.
    func undoBulk() {
        guard let result = bulkResult, !bulkBusy, !result.undoable.isEmpty else { return }
        bulkBusy = true
        let boxes = mailboxes
        Task { @MainActor [weak self] in
            guard let self else { return }
            var restored = 0
            var failed = 0
            for snapshot in result.undoable.reversed() {
                do {
                    try await self.undoBulkItem(result.operation, snapshot: snapshot, boxes: boxes)
                    restored += 1
                } catch { failed += 1 }
            }
            self.bulkBusy = false
            self.bulkUndoAvailable = false
            self.banner = failed == 0 ? "Undid \(restored) message\(restored == 1 ? "" : "s")." : "Undid \(restored) messages; \(failed) could not be restored safely."
            self.reload(keepSelection: true)
        }
    }

    private func undoBulkItem(_ operation: MailBulkOperation, snapshot: MailBulkSnapshot, boxes: [MailMailbox]) async throws {
        guard let source = boxes.first(where: { $0.rowID == snapshot.sourceMailboxID }) else { throw LauncherError("The original mailbox is unavailable.") }
        switch operation {
        case .markRead(let read): try await MailActions.setRead(!read, snapshot.message, in: source)
        case .flag(let flagged): try await MailActions.setFlagged(!flagged, snapshot.message, in: source)
        case .archive:
            guard let destination = MailMailbox.archive(for: source.accountID, in: boxes) else { throw LauncherError("The Archive mailbox is unavailable.") }
            try await moveBack(snapshot, from: destination, to: source)
        case .move(let mailboxID):
            guard let destination = boxes.first(where: { $0.rowID == mailboxID }) else { throw LauncherError("The destination mailbox is unavailable.") }
            try await moveBack(snapshot, from: destination, to: source)
        case .trash:
            guard let destination = boxes.first(where: { $0.accountID == source.accountID && $0.role == .trash }) else { throw LauncherError("The Trash mailbox is unavailable.") }
            try await moveBack(snapshot, from: destination, to: source)
        }
    }

    private func moveBack(_ snapshot: MailBulkSnapshot, from: MailMailbox, to: MailMailbox) async throws {
        var message = snapshot.message
        message.mailbox = from.rowID
        try await MailActions.move(message, from: from, to: to)
    }
}
