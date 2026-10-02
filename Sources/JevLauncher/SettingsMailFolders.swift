import SwiftUI
import LauncherCore

struct MailFolderChoice: Identifiable {
    var name: String
    var role: MailMailbox.Role
    var id: String { name }
}

struct MailFoldersSheet: View {
    let account: NativeMailAccount
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [MailFolderChoice] = []
    @State private var selected: [MailMailbox.Role: String] = [:]
    @State private var error: String?
    private let roles: [MailMailbox.Role] = [.sent, .drafts, .archive, .trash, .junk]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folders for " + account.email).font(.headline)
            Text("Use the folders reported by your mail server, or select them here. Delete only moves messages to the selected Trash folder.")
                .font(.caption).foregroundStyle(.secondary)
            if folders.isEmpty { Text("Folders appear after the first sync.").foregroundStyle(.secondary) }
            else {
                Form {
                    ForEach(roles, id: \.self) { role in
                        Picker(role.rawValue.capitalized, selection: Binding(get: { selected[role] ?? "" }, set: { selected[role] = $0 })) {
                            Text("None").tag("")
                            ForEach(folders.filter { $0.role != .inbox }) { Text($0.name).tag($0.name) }
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do {
                        let names = selected.values.filter { !$0.isEmpty }
                        guard Set(names).count == names.count else { throw LauncherError("Select a different folder for each role.") }
                        var mapping = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0.role == .inbox ? MailMailbox.Role.inbox : .other) })
                        for (role, name) in selected where !name.isEmpty { mapping[name] = role }
                        try NativeMailCenter.shared.updateFolders(account, mapping: mapping)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(folders.isEmpty)
            }
        }.padding(20).frame(width: 490)
        .task {
            do {
                folders = try NativeMailCenter.cachedFolders(account.id)
                for role in roles {
                    let matches = folders.filter { $0.role == role }
                    if matches.count == 1 { selected[role] = matches[0].name }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension NativeMailCenter {
    nonisolated static func cachedFolders(_ accountID: String) throws -> [MailFolderChoice] {
        let db = try SQLiteReader(path: NativeMailStore.indexPath(root: root))
        return try db.rows("SELECT name, role FROM mailboxes WHERE account = ? ORDER BY name", [.text(accountID)]).compactMap {
            guard let name = $0.first?.text else { return nil }
            return .init(name: name, role: $0[1].text.flatMap(MailMailbox.Role.init(rawValue:)) ?? .other)
        }
    }
}
