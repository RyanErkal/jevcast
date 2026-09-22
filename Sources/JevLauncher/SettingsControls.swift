import SwiftUI
import AppKit
import Combine

/// Permission status row with a live tick and a single action.
struct PermissionRow: View {
    let permission: Permission
    var request: (() -> Void)? = nil
    @State private var granted = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(granted ? "Allowed" : permission.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Allow…") {
                    if let request { request() } else { permission.openSystemSettings() }
                }.controlSize(.small)
            }
        }
        .onAppear { granted = permission.isGranted }
        .onReceive(refresh) { _ in granted = permission.isGranted }
    }
}

/// Folder rows for a grouped Form section: one row per folder with a remove
/// button, an empty-state row, and an add button.
struct FolderList: View {
    @Binding var folders: [String]
    var emptyText = "No folders"
    var addTitle = "Add folder…"
    var onChange: () -> Void = {}
    var body: some View {
        if folders.isEmpty {
            Text(emptyText).foregroundStyle(.secondary)
        }
        ForEach(folders, id: \.self) { path in
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(FileManager.default.displayName(atPath: path)).lineLimit(1)
                Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                RemoveButton(label: "Remove " + (path as NSString).lastPathComponent) { remove(path) }
            }
        }
        HStack {
            AddButton(title: addTitle, action: add)
            Spacer()
        }
    }
    private func add() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        folders = Array(Set(folders + picker.urls.map(\.path))).sorted()
        onChange()
    }
    private func remove(_ path: String) {
        folders.removeAll { $0 == path }
        onChange()
    }
}

/// Borderless "+" button with a visible title, for adding a row to a Form section.
struct AddButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: "plus") }
            .buttonStyle(.borderless)
    }
}

/// Borderless "−" button that removes one Form row.
struct RemoveButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Two-column keyboard reference for the window shortcuts, drawn with the launcher's key chips.
/// Text does not dim itself when disabled, so the table reads `isEnabled`.
struct ShortcutTable: View {
    @Environment(\.isEnabled) private var isEnabled
    private let rows: [(keys: [String], action: String)] = [
        (["←", "→", "↑", "↓"], "Halves"), (["U", "I", "J", "K"], "Quarters"), (["1", "2", "3"], "Thirds"),
        (["↩"], "Maximise"), (["Z"], "Restore"), (["N", "P"], "Next / previous display")
    ]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            ForEach(rows, id: \.action) { row in
                GridRow {
                    HStack(spacing: 3) { ForEach(row.keys, id: \.self) { KeyChip($0) } }
                        .foregroundStyle(isEnabled ? .secondary : .tertiary)
                        .accessibilityHidden(true)
                    Text(row.action).font(.caption).foregroundStyle(isEnabled ? .primary : .tertiary)
                        .accessibilityLabel(row.action + ": " + row.keys.joined(separator: " "))
                }
            }
        }
    }
}
