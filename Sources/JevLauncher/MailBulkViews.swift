import Foundation
import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

/// Selection and filter details inside the mailbox's tools menu.
struct MailListTools: View {
    @ObservedObject var model: MailModel

    var body: some View {
        Group {
            if model.filterIsActive {
                Text("\(model.filter.activeCount) active filters")
                Button("Clear filters") { model.clearFilters() }
            }
            if model.conversationMetadataUnknownCount > 0 {
                Text("\(model.conversationMetadataUnknownCount) messages have no downloaded thread headers")
            }
            Button("Select all loaded") { model.selectAllLoaded() }
            if !model.selectedMessageIDs.isEmpty {
                Text("\(model.selectedMessageIDs.count) selected")
                Button("Clear selection") { model.clearSelection() }
                Divider()
                // Only what every selected mailbox allows, by the same rule as the row menu.
                if allows(.markRead(true)) {
                    Button("Mark Read") { model.bulk(.markRead(true)) }
                    Button("Mark Unread") { model.bulk(.markRead(false)) }
                }
                if allows(.flag(true)) {
                    Button("Flag") { model.bulk(.flag(true)) }
                    Button("Unflag") { model.bulk(.flag(false)) }
                }
                if allows(.archive) { Button("Archive") { model.bulk(.archive) } }
                if allows(.move(mailboxID: 0)), !model.bulkMoveDestinations.isEmpty {
                    Menu("Move To") {
                        ForEach(model.bulkMoveDestinations) { destination in
                            Button(destination.path) { model.bulk(.move(mailboxID: destination.rowID)) }
                        }
                    }
                }
                if allows(.trash) { Button("Move to Trash", role: .destructive) { model.bulk(.trash) } }
            }
            if model.bulkUndoAvailable { Button("Undo last bulk change") { model.undoBulk() } }
        }.disabled(model.bulkBusy)
    }

    private func allows(_ operation: MailBulkOperation) -> Bool { model.bulkRefusal(operation) == nil }
}

/// The bar below the list while two or more conversations are selected: the count, then Archive,
/// Delete, Mark Read, Mark Unread, Flag, Move To, and Deselect. Each runs the same action as the
/// list's ⋯ menu and the right-click menu, and offers only what the selected mailboxes allow.
struct MailBulkBar: View {
    @ObservedObject var model: MailModel
    var page: MailPage?

    var body: some View {
        let ids = model.selectedConversationRowIDs
        if ids.count > 1 {
            let actions = MailRowMenu.bulkActions(model.rowMenuContext(ids, features: page?.features))
            // A narrow column shows the count alone, so every button keeps its place.
            ViewThatFits(in: .horizontal) {
                bar(ids, actions, count: "\(ids.count) selected")
                bar(ids, actions, count: "\(ids.count)")
            }
            .buttonStyle(MailIconButtonStyle()).font(.system(size: 13))
            .disabled(model.bulkBusy)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain).accessibilityLabel("\(ids.count) selected")
        }
    }

    private func bar(_ ids: Set<Int64>, _ actions: [MailRowAction], count: String) -> some View {
        HStack(spacing: 0) {
            Text(count).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            if actions.contains(.archive) { button("archivebox", MailRowAction.archive.help()) { model.runRowAction(.archive, on: ids, page: page) } }
            if actions.contains(.delete) { button("trash", MailRowAction.delete.help()) { model.runRowAction(.delete, on: ids, page: page) } }
            if actions.contains(.readToggle) {
                button("envelope.open", "Mark as Read") { model.bulk(.markRead(true)) }
                button("envelope.badge", "Mark as Unread") { model.bulk(.markRead(false)) }
            }
            if actions.contains(.flagToggle) {
                let flagged = model.rowsAreFlagged(ids)
                button(flagged ? "flag.slash" : "flag", flagged ? "Unflag" : "Flag") { model.runRowAction(.flagToggle, on: ids, page: page) }
            }
            if actions.contains(.move) {
                Menu {
                    ForEach(model.bulkMoveDestinations) { box in Button(box.path) { model.moveRows(ids, to: box) } }
                } label: { Image(systemName: "folder") }
                .menuIndicator(.hidden).fixedSize().help("Move To").accessibilityLabel("Move To")
            }
            button("xmark", "Deselect (Escape)") { _ = model.narrowSelection() }
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.help(help).accessibilityLabel(help)
    }
}

/// A drop destination for a mailbox. The dragged payload is a message row ID from the same
/// launcher list. It never accepts arbitrary file URLs or executes dropped text.
struct MailMailboxDropDelegate: DropDelegate {
    let destination: MailMailbox
    let model: MailModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.text])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.text.identifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8), let rowID = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                Task { @MainActor in model.moveMessage(rowID, to: destination) }
            }
        }
        return true
    }
}
