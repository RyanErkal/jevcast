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

/// How long the Undo note stays. While the pointer is on the note, it does not run out; after the
/// pointer leaves, the time it had left comes back, and at least `afterHover` seconds.
struct MailUndoCountdown: Equatable {
    static let seconds: TimeInterval = 8
    static let afterHover: TimeInterval = 3

    private(set) var deadline: Date
    private(set) var hovering = false
    /// The time that was left when the pointer came onto the note.
    private var leftAtHover: TimeInterval = 0

    init(start: Date, seconds: TimeInterval = Self.seconds) { deadline = start.addingTimeInterval(seconds) }

    /// The time stops while the pointer is on the note. When it leaves, the note gets the time it
    /// had when the pointer came, and at least `afterHover` seconds.
    mutating func hover(_ on: Bool, at now: Date) {
        guard on != hovering else { return }
        hovering = on
        if on { leftAtHover = max(0, deadline.timeIntervalSince(now)) }
        else { deadline = now.addingTimeInterval(max(leftAtHover, Self.afterHover)) }
    }

    func expired(at now: Date) -> Bool { !hovering && now >= deadline }
    /// How long to wait before checking again.
    func wait(at now: Date) -> TimeInterval { hovering ? 0.25 : max(0.05, deadline.timeIntervalSince(now)) }
}

/// What one undoable change has done so far. It is kept apart from the Undo note, so Undo pressed
/// while the change is still running still learns which messages moved.
struct MailChangeProgress: Equatable {
    var moved: [MailBulkSnapshot] = []
    /// Messages whose move has not finished yet.
    var remaining: Int
}

extension MailModel {
    /// Runs a change that moves messages out of the list, and keeps what Undo needs to move them back.
    func undoably(_ operation: MailBulkOperation, title: String, _ items: [(MailSummary, MailMailbox)], name: String? = nil,
                  _ action: @escaping (MailSummary, MailMailbox) async throws -> Void) {
        let change = MailUndoableChange(id: UUID(), operation: operation, title: title)
        // A new change replaces the note in place, so a pointer resting on it still holds its time.
        let hovering = lastChange != nil && undoCountdown?.hovering == true
        // The change it replaces can no longer be undone.
        if let old = lastChange { changeProgress[old.id] = nil }
        banner = nil
        lastChange = change
        changeProgress[change.id] = MailChangeProgress(remaining: items.count)
        let label = name ?? title.lowercased()
        for (message, box) in items {
            let known = conversationHeaders[message.rowID]?.messageID
            perform(label, message: message, removes: true, failed: { [weak self] in self?.finishChange(change.id, moved: nil) }) { [weak self] in
                // Read before the move: afterwards the server gives the message a new number.
                let messageID = await MailActions.messageID(message, in: box) ?? known
                try await action(message, box)
                self?.finishChange(change.id, moved: MailBulkSnapshot(message: message, sourceMailboxID: box.rowID, accountID: box.accountID,
                                                                      expectedMessageID: messageID))
            }
        }
        undoCountdown = MailUndoCountdown(start: Date(), seconds: undoSeconds)
        if hovering { undoCountdown?.hover(true, at: Date()) }
        Task { @MainActor [weak self] in
            while let wait = self?.undoTick(change.id) {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// One message of change `id` finished: `moved` when the server took it, nil when it failed.
    /// The messages that moved stay undoable when others failed; with none moved, Undo goes.
    private func finishChange(_ id: UUID, moved: MailBulkSnapshot?) {
        guard var progress = changeProgress[id] else { return }
        progress.remaining -= 1
        if let moved { progress.moved.append(moved) }
        changeProgress[id] = progress
        guard lastChange?.id == id else { return }
        lastChange?.moved = progress.moved
        if progress.remaining <= 0, progress.moved.isEmpty {
            lastChange = nil; undoCountdown = nil; changeProgress[id] = nil
        }
    }

    /// Ends the Undo note of `id` when its time is up. Returns how long to wait before the next
    /// check, or nil when the note is gone.
    private func undoTick(_ id: UUID) -> TimeInterval? {
        guard lastChange?.id == id, let countdown = undoCountdown else { return nil }
        let now = Date()
        if countdown.expired(at: now) { lastChange = nil; undoCountdown = nil; changeProgress[id] = nil; return nil }
        return countdown.wait(at: now)
    }

    /// What ⌘Z undoes now: a send waiting for its time comes first, then the last change.
    enum UndoKeyTarget: Equatable { case none, send, change }
    var undoKeyTarget: UndoKeyTarget { pendingSend != nil ? .send : lastChange != nil ? .change : .none }

    /// The pointer moved onto or off the Undo note.
    func hoverUndo(_ on: Bool) { undoCountdown?.hover(on, at: Date()) }

    /// Puts the last change back. It waits for the change itself to finish first, so it never
    /// races it, and it moves only the messages that the change moved. An Undo you pressed is
    /// never dropped: it waits behind other work, such as a bulk action, then runs; when it still
    /// cannot run, a note says so.
    func undoLastChange() {
        guard let change = lastChange else { return }
        lastChange = nil
        undoCountdown = nil
        Task { @MainActor [weak self] in
            await self?.waitForActions()
            guard let self else { return }
            // What moved, also what finished after Undo was pressed. The change may have failed;
            // then its own note already says so and nothing moved.
            let moved = self.changeProgress[change.id]?.moved ?? []
            guard !moved.isEmpty else { self.changeProgress[change.id] = nil; return }
            let record = MailBulkResult(operation: change.operation, reviewed: moved, succeeded: moved, undoable: moved)
            await self.waitForBulkWork()
            self.changeProgress[change.id] = nil
            guard !self.bulkBusy else {
                self.banner = "Undo could not run while another change was running. Nothing was put back."
                return
            }
            self.undoBulk(record)
        }
    }

    /// Waits until no bulk action or bulk undo runs.
    func waitForBulkWork() async {
        while bulkBusy, let work = bulkWork {
            await work.value
            // The same work still holds the flag: waiting again would never end.
            if bulkBusy, bulkWork == work { return }
        }
    }
}
