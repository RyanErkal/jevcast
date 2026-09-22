import SwiftUI

/// The user's own commands, in Settings › Search.
struct CustomCommandsSection: View {
    @ObservedObject var preferences: Preferences
    /// The command being edited, or a new blank one.
    @State private var editing: CustomCommand?

    var body: some View {
        Section {
            if preferences.customCommands.isEmpty { Text("No commands").foregroundStyle(.secondary) }
            ForEach(preferences.customCommands) { command in
                HStack(spacing: 8) {
                    Button { editing = command } label: {
                        HStack(spacing: 6) {
                            Text(command.name).fontWeight(.medium)
                            Text("·").foregroundStyle(.tertiary)
                            Text(command.command).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit command")
                    RemoveButton(label: "Remove command " + command.name) { preferences.customCommands.removeAll { $0.id == command.id } }
                }
            }
            HStack {
                AddButton(title: "Add command…") { editing = CustomCommand(name: "", command: "") }
                Spacer()
            }
            Text("Type the name in the launcher to run it in zsh from your home folder. Jev can choose a command by its name. It never sees or writes the command text.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Your commands") }
        .sheet(item: $editing) { command in
            CommandSheet(original: command, isNew: !preferences.customCommands.contains { $0.id == command.id }) { saved in
                if let index = preferences.customCommands.firstIndex(where: { $0.id == saved.id }) {
                    preferences.customCommands[index] = saved
                } else {
                    preferences.customCommands.append(saved)
                }
            }
        }
    }
}

/// Adds or edits one custom command.
struct CommandSheet: View {
    let original: CustomCommand
    let isNew: Bool
    let save: (CustomCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String

    init(original: CustomCommand, isNew: Bool, save: @escaping (CustomCommand) -> Void) {
        self.original = original; self.isNew = isNew; self.save = save
        _name = State(initialValue: original.name)
        _command = State(initialValue: original.command)
    }
    var body: some View {
        SettingsSheet(confirmTitle: isNew ? "Add" : "Save", canConfirm: !trimmed(name).isEmpty && !trimmed(command).isEmpty, confirm: commit) {
            Section {
                TextField("Name", text: $name, prompt: Text("Open project"))
                TextField("Command", text: $command, prompt: Text("open -a Xcode ~/Dev/app"))
                    .font(.system(.body, design: .monospaced))
            } footer: {
                Text("Runs with zsh -lc in your home folder. Only run commands you trust.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func commit() {
        save(CustomCommand(id: original.id, name: trimmed(name), command: trimmed(command)))
        dismiss()
    }
}
