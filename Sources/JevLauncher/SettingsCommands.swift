import LauncherCore
import SwiftUI

/// Settings › Commands: your own commands, workflows, and snippets.
struct CommandSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var catalogue: AppCatalogue
    private enum Sheet: Identifiable {
        case command(CustomCommand), workflow(Workflow), snippet(Snippet)
        var id: String {
            switch self {
            case .command(let item): return "command:" + item.id
            case .workflow(let item): return "workflow:" + item.id
            case .snippet(let item): return "snippet:" + item.id
            }
        }
    }
    @State private var sheet: Sheet?

    var body: some View {
        Form {
            Section {
                if preferences.customCommands.isEmpty { Text("No commands").foregroundStyle(.secondary) }
                ForEach(preferences.customCommands) { command in
                    ItemRow(title: command.name, detail: command.command, monospaced: true,
                            edit: { sheet = .command(command) },
                            remove: { preferences.customCommands.removeAll { $0.id == command.id } })
                }
                HStack { AddButton(title: "Add command…") { sheet = .command(CustomCommand(name: "", command: "")) }; Spacer() }
                Text("Type the name in the launcher to run it with zsh from your home folder. Put {input} in the command to pass text typed after the name, such as “open repo swift”. Jev can choose a command by name. It never sees or writes command text.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Your commands") }

            Section {
                if preferences.workflows.isEmpty { Text("No workflows").foregroundStyle(.secondary) }
                ForEach(preferences.workflows) { workflow in
                    ItemRow(title: workflow.name, detail: "\(workflow.steps.count) steps", monospaced: false,
                            edit: { sheet = .workflow(workflow) },
                            remove: { preferences.workflows.removeAll { $0.id == workflow.id } })
                }
                HStack { AddButton(title: "Add workflow…") { sheet = .workflow(Workflow(name: "", steps: [])) }; Spacer() }
                Text("Run several actions from one name, such as “Coding”: open Xcode, Left Two Thirds, open Terminal, Right Third. A window step arranges the app opened in the step before it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Workflows") }

            Section {
                if preferences.snippets.isEmpty { Text("No snippets").foregroundStyle(.secondary) }
                ForEach(preferences.snippets) { snippet in
                    ItemRow(title: snippet.name, detail: snippet.text.replacingOccurrences(of: "\n", with: " "), monospaced: false,
                            edit: { sheet = .snippet(snippet) },
                            remove: { preferences.snippets.removeAll { $0.id == snippet.id } })
                }
                HStack { AddButton(title: "Add snippet…") { sheet = .snippet(Snippet(name: "", text: "")) }; Spacer() }
                Text("Type the name to copy the text, or press Shift–Return to paste it. {date}, {time}, and {clipboard} are filled in when you use it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Snippets") }
        }
        .formStyle(.grouped)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .command(let command):
                CommandSheet(original: command, isNew: !preferences.customCommands.contains { $0.id == command.id }) { saved in
                    upsert(saved, in: &preferences.customCommands)
                }
            case .workflow(let workflow):
                WorkflowSheet(original: workflow, isNew: !preferences.workflows.contains { $0.id == workflow.id },
                              apps: catalogue.entries, commands: preferences.customCommands) { saved in
                    upsert(saved, in: &preferences.workflows)
                }
            case .snippet(let snippet):
                SnippetSheet(original: snippet, isNew: !preferences.snippets.contains { $0.id == snippet.id }) { saved in
                    upsert(saved, in: &preferences.snippets)
                }
            }
        }
    }

    private func upsert<T: Identifiable>(_ item: T, in list: inout [T]) {
        if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item } else { list.append(item) }
    }
}

private struct ItemRow: View {
    let title: String
    let detail: String
    let monospaced: Bool
    let edit: () -> Void
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: edit) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    Text("·").foregroundStyle(.tertiary)
                    Text(detail).font(monospaced ? .system(.body, design: .monospaced) : .body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit")
            RemoveButton(label: "Remove " + title, action: remove)
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
    @State private var output: CustomCommand.Output

    init(original: CustomCommand, isNew: Bool, save: @escaping (CustomCommand) -> Void) {
        self.original = original; self.isNew = isNew; self.save = save
        _name = State(initialValue: original.name)
        _command = State(initialValue: original.command)
        _output = State(initialValue: original.output)
    }
    var body: some View {
        SettingsSheet(confirmTitle: isNew ? "Add" : "Save", canConfirm: !trimmed(name).isEmpty && !trimmed(command).isEmpty, confirm: commit) {
            Section {
                TextField("Name", text: $name, prompt: Text("Open repo"))
                TextField("Command", text: $command, prompt: Text("open ~/Dev/{input}"))
                    .font(.system(.body, design: .monospaced))
                Picker("When it finishes", selection: $output) {
                    ForEach(CustomCommand.Output.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Runs with zsh -lc in your home folder. {input} is passed as a quoted argument, never as command text. Only run commands you trust.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func commit() {
        save(CustomCommand(id: original.id, name: trimmed(name), command: trimmed(command), output: output))
        dismiss()
    }
}

/// Adds or edits one snippet.
struct SnippetSheet: View {
    let original: Snippet
    let isNew: Bool
    let save: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var text: String

    init(original: Snippet, isNew: Bool, save: @escaping (Snippet) -> Void) {
        self.original = original; self.isNew = isNew; self.save = save
        _name = State(initialValue: original.name)
        _text = State(initialValue: original.text)
    }
    var body: some View {
        SettingsSheet(confirmTitle: isNew ? "Add" : "Save", canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty && !text.isEmpty, confirm: commit) {
            Section {
                TextField("Name", text: $name, prompt: Text("Email sign-off"))
                TextField("Text", text: $text, prompt: Text("Thanks,\nRyan"), axis: .vertical)
                    .lineLimit(3...8)
            } footer: {
                Text("{date}, {time}, and {clipboard} are filled in on this Mac when you use the snippet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func commit() {
        save(Snippet(id: original.id, name: name.trimmingCharacters(in: .whitespaces), text: text))
        dismiss()
    }
}

/// Adds or edits one workflow: a name and an ordered list of steps.
struct WorkflowSheet: View {
    let original: Workflow
    let isNew: Bool
    let apps: [AppEntry]
    let commands: [CustomCommand]
    let save: (Workflow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var steps: [Workflow.Step]

    init(original: Workflow, isNew: Bool, apps: [AppEntry], commands: [CustomCommand], save: @escaping (Workflow) -> Void) {
        self.original = original; self.isNew = isNew; self.apps = apps.filter { $0.launchURL == nil }; self.commands = commands; self.save = save
        _name = State(initialValue: original.name)
        _steps = State(initialValue: original.steps)
    }

    var body: some View {
        SettingsSheet(confirmTitle: isNew ? "Add" : "Save", canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty && !steps.isEmpty && steps.allSatisfy { !$0.value.isEmpty }, confirm: commit) {
            Section {
                TextField("Name", text: $name, prompt: Text("Coding"))
            }
            Section {
                ForEach($steps) { $step in
                    HStack(spacing: 8) {
                        Picker("", selection: $step.kind) {
                            ForEach(Workflow.Step.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                        .onChange(of: step.kind) { _, kind in step.value = defaultValue(kind) }
                        valuePicker($step)
                        RemoveButton(label: "Remove step") { steps.removeAll { $0.id == step.id } }
                    }
                }
                HStack {
                    AddButton(title: "Add step") { steps.append(Workflow.Step(kind: .app, value: defaultValue(.app))) }
                    Spacer()
                }
            } header: { Text("Steps") }
        }
    }

    @ViewBuilder private func valuePicker(_ step: Binding<Workflow.Step>) -> some View {
        switch step.wrappedValue.kind {
        case .app:
            Picker("", selection: step.value) { ForEach(apps) { Text($0.name).tag($0.id) } }.labelsHidden()
        case .window:
            Picker("", selection: step.value) { ForEach(WindowAction.allCases) { Text($0.title).tag($0.rawValue) } }.labelsHidden()
        case .command:
            Picker("", selection: step.value) { ForEach(SystemCommands.all) { Text($0.title).tag($0.id) } }.labelsHidden()
        case .custom:
            Picker("", selection: step.value) {
                Text("Choose a command").tag("")
                ForEach(commands) { Text($0.name).tag($0.id) }
            }.labelsHidden()
        case .shortcut:
            TextField("", text: step.value, prompt: Text("Shortcut name"))
        case .wait:
            TextField("", text: step.value, prompt: Text("Seconds"))
        }
    }

    private func defaultValue(_ kind: Workflow.Step.Kind) -> String {
        switch kind {
        case .app: return apps.first?.id ?? ""
        case .window: return WindowAction.leftHalf.rawValue
        case .command: return SystemCommands.all.first?.id ?? ""
        case .custom: return commands.first?.id ?? ""
        case .shortcut: return ""
        case .wait: return "1"
        }
    }

    private func commit() {
        save(Workflow(id: original.id, name: name.trimmingCharacters(in: .whitespaces), steps: steps))
        dismiss()
    }
}
