import SwiftUI
import LauncherCore

/// The right-click menu of list rows. SwiftUI passes the rows it acts on: the whole selection
/// when the clicked row is in it, otherwise the clicked row alone. It offers only what the rows'
/// mailboxes allow, with each action's key.
struct MailRowMenuContent: View {
    let model: MailModel
    let page: MailPage?
    let ids: Set<Int64>

    var body: some View {
        let context = model.rowMenuContext(ids, features: page?.features)
        let groups = MailRowMenu.groups(context)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group, id: \.self) { action in item(action, context: context) }
        }
    }

    @ViewBuilder private func item(_ action: MailRowAction, context: MailRowMenuContext) -> some View {
        if action == .move {
            let members = ids.compactMap { model.conversation(row: $0) }
                .flatMap { ids.count > 1 ? $0.messages.map(\.summary) : [$0.latest.summary] }
            Menu(action.title()) {
                ForEach(model.moveDestinations(for: members)) { box in
                    Button(box.path) { model.moveRows(ids, to: box) }
                }
            }
        } else {
            Button(title(action, context: context),
                   role: action == .delete || action == .deleteAllFromSender ? .destructive : nil) {
                model.runRowAction(action, on: ids, page: page)
            }
            .keyboardShortcut(action.shortcut)
        }
    }

    private func title(_ action: MailRowAction, context: MailRowMenuContext) -> String {
        let sender = ids.count == 1 ? ids.first.flatMap { model.conversation(row: $0)?.latest.summary.sender } ?? "" : ""
        let name = action.title(unread: model.rowsHaveUnread(ids), flagged: model.rowsAreFlagged(ids),
                                junk: context.roles == [.junk], sender: sender)
        if action == .delete, ids.count > 1 { return "Delete \(ids.count) Conversations" }
        return name
    }
}
