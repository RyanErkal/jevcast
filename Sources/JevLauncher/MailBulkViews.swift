import Foundation
import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

/// Header tools that the root workspace can place beside the mailbox title.
/// It deliberately contains no window or panel management.
struct MailListTools: View {
    @ObservedObject var model: MailModel

    var body: some View {
        HStack(spacing: 8) {
            MailFilterButton(model: model)
            if model.filterIsActive {
                MailFilterCoverageText(filter: model.filter,
                                       matchCount: model.filteredResultCount,
                                       metadataUnknownCount: model.filterMetadataUnknownCount,
                                       recipientUnknownCount: model.filterRecipientMetadataUnknownCount,
                                       attachmentUnknownCount: model.filterAttachmentMetadataUnknownCount)
            }
            if model.conversationMetadataUnknownCount > 0 {
                Text("\(model.conversationMetadataUnknownCount) loaded row\(model.conversationMetadataUnknownCount == 1 ? "" : "s") have no cached thread headers")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Thread grouping uses provider IDs or downloaded Message-ID references. Rows without either stay separate.")
            }
            if !model.selectedMessageIDs.isEmpty {
                Text("\(model.selectedMessageIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Select all loaded") { model.selectAllLoaded() }
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
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.bulk(.trash) }
                    if model.bulkUndoAvailable { Divider(); Button("Undo last bulk change") { model.undoBulk() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
            } else if model.bulkUndoAvailable {
                Button("Undo") { model.undoBulk() }.buttonStyle(.link)
            }
            if model.bulkBusy { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.borderless)
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
