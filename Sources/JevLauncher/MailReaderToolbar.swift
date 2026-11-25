import SwiftUI
import LauncherCore

/// The controls above the open message, in their order. At most seven, so the bar fits the
/// narrowest panel. Every other action is in the ⋯ menu or under ⌘K.
enum MailReaderToolbarItem: String, CaseIterable {
    case archive, delete, reply, readToggle, snooze, more, expand

    /// What a screen reader says.
    var title: String {
        switch self {
        case .archive: return "Archive"
        case .delete: return "Delete"
        case .reply: return "Reply"
        case .readToggle: return "Mark as Read or Unread"
        case .snooze: return "Snooze"
        case .more: return "More"
        case .expand: return "Expand"
        }
    }

    /// The tooltip, with the item's key.
    func help(expanded: Bool = false) -> String {
        switch self {
        case .archive: return "Archive (⌘E)"
        case .delete: return "Delete (⌫)"
        case .reply: return "Reply (⌘R). The arrow offers Reply All (⇧⌘R) and Forward (⇧⌘F)."
        case .readToggle: return "Mark as read or unread (⇧⌘U)"
        case .snooze: return "Snooze this message on this Mac (⌃⌘S)"
        case .more: return "More: flag, junk, move, text size, export"
        case .expand: return expanded ? "Show the list (Escape)" : "Expand (Return)"
        }
    }

    /// The items for the message on screen.
    static func items(canSnooze: Bool, canExpand: Bool) -> [Self] {
        allCases.filter { item in
            switch item {
            case .archive, .delete, .reply, .readToggle, .more: return true
            case .snooze: return canSnooze
            case .expand: return canExpand
            }
        }
    }

    /// The ⋯ menu's and ⌘K's item for a conversation's quoted text.
    static func quotedTextTitle(shown: Bool) -> String { shown ? "Hide Quoted Text" : "Show Quoted Text" }
}

extension MailModel {
    /// The reader's bar for the message on screen. Snooze shows only where its account can snooze
    /// and the mailbox rule (`MailRowMenu`) allows it, as for ⌃⌘S and the row menu.
    func readerToolbarItems(features: MailFeatureCenter?, canExpand: Bool) -> [MailReaderToolbarItem] {
        MailReaderToolbarItem.items(canSnooze: MailSnoozeTool.available(self, features) && refusal(.snooze) == nil,
                                    canExpand: canExpand)
    }
}

/// The reader's bar: Archive, Delete, Reply with Reply All and Forward, Read, Snooze, ⋯, Expand.
struct MailReaderToolbar: View {
    @ObservedObject var model: MailModel
    let message: MailSummary
    var expanded: Binding<Bool>?
    var features: MailFeatureCenter?
    @Binding var zoom: Double
    @Binding var fitsWidth: Bool
    @Binding var prefersPlain: Bool
    @State private var exporting = false

    var body: some View {
        let items = model.readerToolbarItems(features: features, canExpand: expanded != nil)
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                control(item)
                if item == .more && exporting { ProgressView().controlSize(.small) }
                if item == .more { Spacer(minLength: 4) }
            }
        }
        .buttonStyle(MailIconButtonStyle()).font(.system(size: 14))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private func control(_ item: MailReaderToolbarItem) -> some View {
        switch item {
        case .archive:
            icon(item, "archivebox") { model.archive() }.disabled(!allows(.archive))
        case .delete:
            icon(item, "trash") { model.delete() }
                .disabled(!allows(.delete, multiple: model.selectedConversationRowIDs.count > 1))
        case .reply:
            if NativeMailCenter.isActive, model.mailbox(message.mailbox)?.role == .drafts {
                Button("Edit Draft") {
                    Task { do { try await model.editSelectedServerDraft() } catch { model.banner = error.localizedDescription } }
                }
                .font(.system(size: 13, weight: .medium)).help("Edit this draft")
            } else { reply.disabled(!allows(.reply)) }
        case .readToggle:
            let unread = model.selected?.read == false
            Button { model.toggleRead() } label: { Image(systemName: unread ? "envelope.open" : "envelope.badge") }
                .help(item.help()).accessibilityLabel(unread ? "Mark as Read" : "Mark as Unread")
                .disabled(!allows(.readToggle))
        case .snooze:
            if let features { MailSnoozeTool(model: model, features: features).help(item.help()) }
        case .more:
            more.help(item.help()).accessibilityLabel(item.title)
        case .expand:
            if let expanded {
                Button {
                    // Expanding a message counts as reading it.
                    if !expanded.wrappedValue { model.noteUserAction() }
                    expanded.wrappedValue.toggle()
                } label: {
                    Image(systemName: expanded.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(item.help(expanded: expanded.wrappedValue))
                .accessibilityLabel(expanded.wrappedValue ? "Show the List" : item.title)
            }
        }
    }

    /// True when the mailbox rule (`MailRowMenu`) lets `action` run here, as the keys and menus check.
    private func allows(_ action: MailRowAction, multiple: Bool = false) -> Bool { model.refusal(action, multiple: multiple) == nil }

    private func icon(_ item: MailReaderToolbarItem, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.help(item.help()).accessibilityLabel(item.title)
    }

    /// Click replies; the arrow opens Reply All and Forward.
    private var reply: some View {
        Menu {
            Button("Reply All (⇧⌘R)") { model.reply(all: true) }.disabled(!allows(.replyAll))
            Button("Forward (⇧⌘F)") { model.forward() }.disabled(!allows(.forward))
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left").labelStyle(.titleAndIcon)
        } primaryAction: { model.reply(all: false) }
        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.visible)
        .font(.system(size: 13, weight: .medium))
        .fixedSize()
        .help(MailReaderToolbarItem.reply.help())
        .accessibilityLabel(MailReaderToolbarItem.reply.title)
    }

    private var more: some View {
        Menu {
            Button(model.selected?.flagged == true ? "Unflag (⇧⌘L)" : "Flag (⇧⌘L)") { model.toggleFlag() }.disabled(!allows(.flagToggle))
            if allows(.junkToggle) {
                Button(model.selectedIsJunk ? "Not Junk: Move to Inbox" : "Mark as Junk (⇧⌘J)") { model.setJunk(!model.selectedIsJunk) }
            }
            let destinations = model.moveDestinations
            if !destinations.isEmpty, allows(.move) {
                Menu("Move To") {
                    ForEach(destinations) { box in Button(box.path) { model.move(to: box) } }
                }
            }
            if let features, model.actionBox(message) != nil {
                Menu("Export") {
                    Button("Message as .eml…") { export([message], .eml, features) }
                    Button("Selected as .mbox…") {
                        export(model.selectedMessages.isEmpty ? [message] : model.selectedMessages, .mbox, features)
                    }
                }
                .disabled(exporting)
            }
            Divider()
            Section("Text Size: \(Int((MailReading.clampZoom(zoom) * 100).rounded()))%") {
                Button("Larger (⌘+)") { zoom = MailReading.zoom(zoom, .larger) }.disabled(zoom >= MailReading.zoomRange.upperBound)
                Button("Smaller (⌘−)") { zoom = MailReading.zoom(zoom, .smaller) }.disabled(zoom <= MailReading.zoomRange.lowerBound)
                Button("Actual Size (⌘0)") { zoom = MailReading.zoom(zoom, .actualSize) }.disabled(abs(zoom - 1) < 0.001)
            }
            Divider()
            Toggle("Load Images from the Web", isOn: $model.loadsImages)
            Toggle("Fit Wide Mail to Width", isOn: $fitsWidth)
            Toggle("Prefer Plain Text", isOn: $prefersPlain)
            // The ••• in a conversation is inside the page, where the keys do not reach; this opens every quote.
            if model.shownThread != nil {
                Button(MailReaderToolbarItem.quotedTextTitle(shown: model.quotesShown)) { model.toggleQuotedText() }
            }
            Divider()
            if model.canUseAIWriting { Button("Summarise") { model.summarise() }.disabled(model.detail == nil || model.aiWritingBusy) }
            if allows(.deleteAllFromSender) {
                Button("Delete All from \(model.selected?.sender ?? "Sender")", role: .destructive) { model.deleteAllFromSender() }
            }
            if !NativeMailCenter.isActive { Button("Open in Mail") { model.openInMail() } }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuIndicator(.hidden).fixedSize()
    }

    private func export(_ messages: [MailSummary], _ format: MailArchiveFormat, _ features: MailFeatureCenter) {
        MailMessageExport.run(messages, format: format, model: model, features: features) { exporting = $0 }
    }
}
