import Foundation
import LauncherCore

/// Actions on list rows: the right-click menu, the buttons under the pointer, and the bar for
/// several rows. Each one runs the model action the reader and ⌘K run, so Undo, the question
/// before Delete All from a sender, and the Trash rules stay the same.
extension MailModel {
    /// The conversation a list row stands for, by its row ID.
    func conversation(row rowID: Int64) -> MailConversation? {
        let groups = conversationGroups
        return conversationIndex.byRow[rowID].map { groups[$0] }
    }

    /// The other mailboxes of one account that `messages` can move to. Empty when they come from
    /// more than one account.
    func moveDestinations(for messages: [MailSummary]) -> [MailMailbox] {
        let accounts = Set(messages.compactMap { actionBox($0)?.accountID })
        guard accounts.count == 1, let account = accounts.first else { return [] }
        let sources = Set(messages.compactMap { actionBox($0)?.rowID })
        return mailboxes.filter { $0.accountID == account && !sources.contains($0.rowID) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// True when `accountID` can snooze on this Mac: Snooze is for Jevcast's own accounts.
    func canSnooze(accountID: String?, features: MailFeatureCenter?) -> Bool {
        guard let accountID, let features else { return false }
        return features.accountChoices.contains { $0.id == accountID }
    }

    /// What a menu on these rows offers.
    func rowMenuContext(_ ids: Set<Int64>, features: MailFeatureCenter?) -> MailRowMenuContext {
        let rows = ids.compactMap { conversation(row: $0) }
        let latest = rows.map(\.latest.summary)
        let boxes = latest.map { actionBox($0) }
        // Several rows act on every loaded message of each conversation, so every one of their
        // mailboxes decides, as the bulk actions check when they run.
        let members = ids.count > 1 ? rows.flatMap { $0.messages.map(\.summary) } : latest
        return MailRowMenuContext(roles: Set(members.map { actionBox($0)?.role }), multiple: ids.count > 1, native: NativeMailCenter.isActive,
                                  canSnooze: ids.count == 1 && canSnooze(accountID: boxes.first??.accountID, features: features),
                                  canMove: !moveDestinations(for: members).isEmpty)
    }

    /// Why `action` cannot run on the message on screen, or nil when it can. The rule is the row
    /// menu's (`MailRowMenu`), so the keys, ⌘K, the reader's bar, and the menus all agree.
    /// `multiple` is true when the action would act on several selected rows, such as Delete.
    func refusal(_ action: MailRowAction, multiple: Bool = false) -> String? {
        guard let message = selected else { return nil }
        let box = actionBox(message)
        // Snooze and Move check their own accounts and folders; this checks the mailbox.
        let context = MailRowMenuContext(roles: [box?.role], multiple: multiple, native: NativeMailCenter.isActive,
                                         canSnooze: true, canMove: true)
        guard !MailRowMenu.offered(action, context) else { return nil }
        if action == .delete, multiple, box?.role == .trash { return "Select one message to delete it for good." }
        let name = action.title(junk: box?.role == .junk).replacingOccurrences(of: "…", with: "")
        return "\(name) is not available in \(box?.name ?? placeTitle)."
    }

    /// Shows why `action` cannot run, and returns true, when the rule refuses it.
    func refuses(_ action: MailRowAction, multiple: Bool = false) -> Bool {
        guard let note = refusal(action, multiple: multiple) else { return false }
        banner = note
        return true
    }

    /// Why a bulk `operation` cannot run on the selected rows, or nil when it can.
    func bulkRefusal(_ operation: MailBulkOperation) -> String? {
        let action: MailRowAction
        switch operation {
        case .archive: action = .archive
        case .trash: action = .delete
        case .markRead: action = .readToggle
        case .flag: action = .flagToggle
        case .move: action = .move
        }
        let roles = Set(selectedMessages.map { actionBox($0)?.role })
        guard !roles.isEmpty else { return nil }
        let context = MailRowMenuContext(roles: roles, multiple: true, native: NativeMailCenter.isActive, canSnooze: false, canMove: true)
        guard !MailRowMenu.offered(action, context) else { return nil }
        if action == .delete, roles.contains(.trash) { return "Select one message to delete it for good." }
        return "\(action.title()) is not available for these messages."
    }

    /// True when any of these rows has an unread message, so the menu offers Mark as Read.
    func rowsHaveUnread(_ ids: Set<Int64>) -> Bool {
        ids.compactMap { conversation(row: $0) }.contains { ids.count > 1 ? $0.hasUnread : !$0.latest.summary.read }
    }

    /// True when every one of these rows is flagged, so the menu offers Unflag.
    func rowsAreFlagged(_ ids: Set<Int64>) -> Bool {
        let rows = ids.compactMap { conversation(row: $0) }
        return !rows.isEmpty && rows.allSatisfy { ids.count > 1 ? $0.isFlagged : $0.latest.summary.flagged }
    }

    /// Makes one row the message the actions use, as a click would, but leaves it unread.
    /// A selection of several rows narrows to this one.
    func targetRow(_ rowID: Int64) {
        if selectedConversationRowIDs != [rowID] { selectConversationRows([rowID]) }
        if selectedID != rowID { select(rowID, byUser: false) }
    }

    /// Several rows become the selection the bulk actions use.
    private func targetRows(_ ids: Set<Int64>) {
        if selectedConversationRowIDs != ids { selectConversationRows(ids) }
    }

    /// Runs `action` on the rows: one row through the reader's action, several through the bulk
    /// actions. Delete of several rows is ⌫'s delete, with its Undo note.
    func runRowAction(_ action: MailRowAction, on ids: Set<Int64>, page: MailPage?) {
        guard let first = ids.first else { return }
        guard ids.count == 1 else {
            let read = rowsHaveUnread(ids), flagged = rowsAreFlagged(ids)
            targetRows(ids)
            switch action {
            case .archive: bulk(.archive)
            case .delete: delete()
            case .readToggle: bulk(.markRead(read))
            case .flagToggle: bulk(.flag(!flagged))
            default: break
            }
            return
        }
        if action == .delete {
            // In Trash a delete is for good, so it acts only on the row you pressed it on, and
            // only while no other row is selected; that row becomes the message on screen first.
            if let row = conversation(row: first)?.latest.summary, actionBox(row)?.role == .trash,
               selectedConversationRowIDs.count <= 1 {
                targetRow(first)
            }
            // Elsewhere Delete under the pointer leaves the message on screen where it is.
            delete(first)
            return
        }
        targetRow(first)
        switch action {
        case .reply: reply(all: false)
        case .replyAll: reply(all: true)
        case .forward: forward()
        case .editDraft:
            Task { @MainActor [weak self] in
                do { _ = try await self?.editSelectedServerDraft() } catch { self?.banner = error.localizedDescription }
            }
        case .archive: archive()
        case .readToggle: toggleRead()
        case .flagToggle: toggleFlag()
        case .snooze: page?.snoozeRow(first)
        case .junkToggle: setJunk(!selectedIsJunk)
        case .deleteAllFromSender: deleteAllFromSender()
        case .move, .delete: break
        }
    }

    /// Moves the rows to `destination`: one row as the reader's Move To, several as the bulk move.
    func moveRows(_ ids: Set<Int64>, to destination: MailMailbox) {
        guard let first = ids.first else { return }
        if ids.count == 1 {
            targetRow(first)
            move(to: destination)
        } else {
            targetRows(ids)
            bulk(.move(mailboxID: destination.rowID))
        }
    }

    /// Escape with several rows selected keeps only the message on screen. False when there is
    /// one row or none.
    func narrowSelection() -> Bool {
        guard selectedConversationRowIDs.count > 1 else { return false }
        if let focused = selectedConversationRowID { selectConversationRows([focused]) } else { clearSelection() }
        return true
    }
}
