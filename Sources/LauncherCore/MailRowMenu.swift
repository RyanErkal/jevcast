import Foundation

/// What a mail list row offers: in its right-click menu, under the pointer, and in the bar for
/// several selected rows. Each item runs the action the reader and ⌘K run.
public enum MailRowAction: String, CaseIterable, Sendable {
    case reply, replyAll, forward, editDraft
    case archive, readToggle, flagToggle, snooze, move
    case junkToggle, delete, deleteAllFromSender

    /// The key that runs the same action on the message on screen.
    public var key: String? {
        switch self {
        case .reply: return "⌘R"
        case .replyAll: return "⇧⌘R"
        case .forward: return "⇧⌘F"
        case .archive: return "⌘E"
        case .readToggle: return "⇧⌘U"
        case .flagToggle: return "⇧⌘L"
        case .snooze: return "⌃⌘S"
        case .move: return "⇧⌘M"
        case .junkToggle: return "⇧⌘J"
        case .delete: return "⌫"
        case .editDraft, .deleteAllFromSender: return nil
        }
    }
}

/// The rows a menu acts on, and what their mailboxes allow.
public struct MailRowMenuContext: Equatable, Sendable {
    /// The roles of the mailboxes the rows are in. Nil when a mailbox is unknown.
    public var roles: Set<MailMailbox.Role?>
    /// More than one conversation: the menu acts on the whole selection.
    public var multiple: Bool
    /// A Jevcast account: Edit Draft imports a server draft.
    public var native: Bool
    /// The row's account can snooze on this Mac.
    public var canSnooze: Bool
    /// There is a folder to move to.
    public var canMove: Bool

    public init(roles: Set<MailMailbox.Role?>, multiple: Bool = false, native: Bool = false, canSnooze: Bool = false, canMove: Bool = true) {
        self.roles = roles; self.multiple = multiple; self.native = native; self.canSnooze = canSnooze; self.canMove = canMove
    }
}

public enum MailRowMenu {
    /// The menu in three groups: answer, organise, remove. Empty groups are left out.
    ///
    /// Drafts offer Edit Draft (Jevcast accounts) instead of Reply. Sent and Trash have no Junk,
    /// Snooze, or Delete All from the sender; Junk offers no reply, Archive, or Snooze. Several rows
    /// drop what acts on one message only, and in Trash they drop Delete, because there a delete is
    /// permanent and goes one message at a time.
    public static func groups(_ context: MailRowMenuContext) -> [[MailRowAction]] {
        let all: [[MailRowAction]] = [[.reply, .replyAll, .forward, .editDraft],
                                      [.archive, .readToggle, .flagToggle, .snooze, .move],
                                      [.junkToggle, .delete, .deleteAllFromSender]]
        return all.map { $0.filter { offered($0, context) } }.filter { !$0.isEmpty }
    }

    /// The menu's actions in order, without the groups.
    public static func actions(_ context: MailRowMenuContext) -> [MailRowAction] { groups(context).flatMap { $0 } }

    /// The buttons under the pointer on one row: Archive, Delete, and Read or Unread, when offered.
    public static func hoverActions(_ context: MailRowMenuContext) -> [MailRowAction] {
        [.archive, .delete, .readToggle].filter { offered($0, context) }
    }

    /// The bar for several selected rows. Delete, Archive, Read, Flag, and Move follow the menu's rules.
    public static func bulkActions(_ context: MailRowMenuContext) -> [MailRowAction] {
        var several = context
        several.multiple = true
        return [.archive, .delete, .readToggle, .flagToggle, .move].filter { offered($0, several) }
    }

    /// True when `action` may run on rows of `context`. The one rule for every way in: the keys,
    /// ⌘K, the reader's bar, the row menu, the bar for several rows, and the list's ⋯ menu.
    public static func offered(_ action: MailRowAction, _ context: MailRowMenuContext) -> Bool {
        guard !context.roles.isEmpty else { return false }
        if context.multiple, singleOnly.contains(action) { return false }
        if action == .snooze, !context.canSnooze { return false }
        if action == .move, !context.canMove { return false }
        if action == .editDraft, !context.native { return false }
        return context.roles.allSatisfy { allowed(action, in: $0, multiple: context.multiple) }
    }

    private static let singleOnly: Set<MailRowAction> = [.reply, .replyAll, .forward, .editDraft, .snooze, .junkToggle, .deleteAllFromSender]

    private static func allowed(_ action: MailRowAction, in role: MailMailbox.Role?, multiple: Bool) -> Bool {
        switch role {
        case .drafts:
            return [.editDraft, .flagToggle, .move, .delete].contains(action)
        case .sent:
            return ![.editDraft, .junkToggle, .snooze, .deleteAllFromSender].contains(action)
        case .trash:
            if action == .delete { return !multiple }
            return ![.editDraft, .archive, .junkToggle, .snooze, .deleteAllFromSender].contains(action)
        case .junk:
            return ![.reply, .replyAll, .forward, .editDraft, .archive, .snooze].contains(action)
        case .archive:
            return ![.editDraft, .archive].contains(action)
        case .inbox, .other, nil:
            return action != .editDraft
        }
    }
}
