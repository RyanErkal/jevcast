import SwiftUI
import LauncherCore

struct MailSidebarRow: View {
    let title: String
    let symbol: String
    var count = 0
    var selected = false
    var expanded: Binding<Bool>? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 12))
                        .frame(width: 16).foregroundStyle(Color.accentColor)
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 4)
                    if count > 0 {
                        Text(count.formatted()).font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary).padding(.horizontal, 6).frame(height: 16)
                            .background(Color.primary.opacity(selected ? 0.10 : 0.06), in: Capsule())
                            .fixedSize().layoutPriority(1)
                    }
                }
                .padding(.leading, 8).padding(.trailing, expanded == nil ? 8 : 0)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            if let expanded {
                Button { expanded.wrappedValue.toggle() } label: {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel((expanded.wrappedValue ? "Collapse " : "Expand ") + title)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            }
        }
        .frame(height: 26)
        .background(selected ? Color.accentColor.opacity(0.14) : hovered ? Color.primary.opacity(0.04) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

struct MailSidebarMailbox: View {
    let box: MailMailbox
    let title: String
    @ObservedObject var model: MailModel
    var expanded: Binding<Bool>? = nil

    var body: some View {
        MailSidebarRow(title: title, symbol: symbol, count: count, selected: model.place == .mailbox(box.rowID), expanded: expanded) {
            model.place = .mailbox(box.rowID)
        }
        .help(help)
        .contextMenu {
            Button(model.isFavorite(box) ? "Remove from Favourites" : "Add to Favourites") { model.toggleFavorite(box) }
        }
    }

    private var help: String {
        if box.initialized == false { return box.path + "\nOpens and downloads this folder" }
        if box.syncComplete == false { return box.path + "\nOlder messages load as you scroll" }
        return box.path
    }
    private var count: Int {
        [.junk, .trash, .drafts].contains(box.role) ? box.serverTotal ?? box.total : box.serverUnread ?? box.unread
    }
    private var symbol: String {
        switch box.role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "exclamationmark.shield"
        case .archive: return "archivebox"
        case .other: return "folder"
        }
    }
}

struct MailSidebarHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
            .padding(.horizontal, 8).accessibilityAddTraits(.isHeader)
    }
}
