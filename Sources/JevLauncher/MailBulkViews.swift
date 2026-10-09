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
                Button("Mark Read") { model.bulk(.markRead(true)) }
                Button("Mark Unread") { model.bulk(.markRead(false)) }
                Button("Flag") { model.bulk(.flag(true)) }
                Button("Unflag") { model.bulk(.flag(false)) }
                Button("Archive") { model.bulk(.archive) }
                if !model.bulkMoveDestinations.isEmpty {
                    Menu("Move To") {
                        ForEach(model.bulkMoveDestinations) { destination in
                            Button(destination.path) { model.bulk(.move(mailboxID: destination.rowID)) }
                        }
                    }
                }
                Button("Move to Trash", role: .destructive) { model.bulk(.trash) }
            }
            if model.bulkUndoAvailable { Button("Undo last bulk change") { model.undoBulk() } }
        }.disabled(model.bulkBusy)
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
