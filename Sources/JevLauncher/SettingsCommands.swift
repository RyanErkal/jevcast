import AppKit
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Library: your own commands, workflows, and snippets, one list at a time.
struct CommandSettings: View {
    enum Part: String, CaseIterable { case commands = "Commands", workflows = "Workflows", snippets = "Snippets" }
    @ObservedObject var preferences: Preferences
    @ObservedObject var catalogue: AppCatalogue
    let resized: () -> Void
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
    @State private var transferMessage = ""
    @State private var pendingImport: PendingImport?
    @AppStorage("settingsLibraryPart") private var part: Part = .commands

    var body: some View {
        Form {
            Section { PaneSections(selection: $part) }
            switch part {
            case .commands: commands
            case .workflows: workflows
            case .snippets: snippets
            }
            Section {
                HStack {
                    Button("Export Library…", action: exportLibrary)
                    Button("Import…", action: importLibrary)
                    Spacer()
                }
                .controlSize(.small)
                InfoCaption(transferMessage.isEmpty ? "Move your library to another Mac as one file." : transferMessage,
                            detail: "The file holds your commands, workflows, snippets, search keywords, and app aliases. Import adds items you do not have yet and changes nothing else. Check imported commands before you run them.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: part) { _, _ in resized() }
        .sheet(item: $pendingImport) { pending in
            ImportReviewSheet(pending: pending) {
                let added = pending.file.merge(into: preferences)
                transferMessage = "Imported \(added) items."
            }
        }
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

    @ViewBuilder private var commands: some View {
        Section {
            if preferences.customCommands.isEmpty {
                ExampleRow(text: "No commands yet.", example: "Start from “Open repo”") {
                    sheet = .command(CustomCommand(name: "Open repo", command: "open ~/Dev/{input}"))
                }
            }
            ForEach(preferences.customCommands) { command in
                ItemRow(title: command.name, detail: command.command, monospaced: true,
                        edit: { sheet = .command(command) },
                        remove: { preferences.customCommands.removeAll { $0.id == command.id } })
            }
            HStack { AddButton(title: "Add command…") { sheet = .command(CustomCommand(name: "", command: "")) }; Spacer() }
        } header: { Text("Your commands") } footer: {
            InfoCaption("Type the name in the launcher to run it.",
                        detail: "Runs with zsh from your home folder. Put {input} in the command to pass text typed after the name, such as “open repo swift”. Jev can choose a command by name. It never sees or writes command text.")
        }
    }
    @ViewBuilder private var workflows: some View {
        Section {
            if preferences.workflows.isEmpty {
                ExampleRow(text: "No workflows yet.", example: "Start from “Coding”") { sheet = .workflow(codingExample) }
            }
            ForEach(preferences.workflows) { workflow in
                ItemRow(title: workflow.name, detail: "\(workflow.steps.count) steps", monospaced: false,
                        edit: { sheet = .workflow(workflow) },
                        remove: { preferences.workflows.removeAll { $0.id == workflow.id } })
            }
            HStack { AddButton(title: "Add workflow…") { sheet = .workflow(Workflow(name: "", steps: [])) }; Spacer() }
        } header: { Text("Workflows") } footer: {
            InfoCaption("Run several actions from one name.",
                        detail: "For example “Coding”: open Xcode, Left Two Thirds, open Terminal, Right Third. A window step arranges the app opened in the step before it.")
        }
    }
    @ViewBuilder private var snippets: some View {
        Section {
            if preferences.snippets.isEmpty {
                ExampleRow(text: "No snippets yet.", example: "Start from “Sign-off”") {
                    sheet = .snippet(Snippet(name: "Sign-off", text: "Thanks,\n" + NSFullUserName()))
                }
            }
            ForEach(preferences.snippets) { snippet in
                ItemRow(title: snippet.name, detail: snippet.text.replacingOccurrences(of: "\n", with: " "), monospaced: false,
                        edit: { sheet = .snippet(snippet) },
                        remove: { preferences.snippets.removeAll { $0.id == snippet.id } })
            }
            HStack { AddButton(title: "Add snippet…") { sheet = .snippet(Snippet(name: "", text: "")) }; Spacer() }
        } header: { Text("Snippets") } footer: {
            InfoCaption("Type the name to copy, Shift–Return to paste.",
                        detail: "{date}, {time}, and {clipboard} are filled in when you use the snippet.")
        }
    }
    /// A starting point the user edits and saves. An app that is not installed is left out with its window step.
    private var codingExample: Workflow {
        let pairs: [(app: String, window: WindowAction)] = [("Xcode", .leftTwoThirds), ("Terminal", .rightThird)]
        let steps = pairs.flatMap { pair -> [Workflow.Step] in
            guard let app = catalogue.entries.first(where: { $0.name == pair.app }) else { return [] }
            return [Workflow.Step(kind: .app, value: app.id), Workflow.Step(kind: .window, value: pair.window.rawValue)]
        }
        return Workflow(name: "Coding", steps: steps)
    }

    private func exportLibrary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AppIdentity.name + " Library.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryFile(preferences).encoded().write(to: url, options: .atomic)
            transferMessage = "Exported."
        } catch { transferMessage = "Could not export: " + error.localizedDescription }
    }
    private func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (file, skipped) = try LibraryFile.decode(Data(contentsOf: url)).additions(to: preferences)
            if file.count == 0 { transferMessage = "Nothing new to import."; return }
            pendingImport = PendingImport(file: file, skipped: skipped)
        } catch { transferMessage = "Could not import: " + error.localizedDescription }
    }

    private func upsert<T: Identifiable>(_ item: T, in list: inout [T]) {
        if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item } else { list.append(item) }
    }
}

struct PendingImport: Identifiable {
    let id = UUID()
    let file: LibraryFile
    let skipped: Int
}

/// Shows every item an import would add, with the full text of each command, before anything changes.
private struct ImportReviewSheet: View {
    let pending: PendingImport
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var file: LibraryFile { pending.file }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(file.count) items?").font(.headline)
            Text("Imported commands run with zsh when you type their name, and Jev can pick them. Read each one first.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if !file.commands.isEmpty {
                    Section("Commands") {
                        ForEach(file.commands) { command in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.name)
                                Text(command.command).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                if !file.workflows.isEmpty {
                    Section("Workflows") {
                        ForEach(file.workflows) { workflow in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workflow.name)
                                Text(workflow.steps.map { $0.kind.title + ": " + $0.value }.joined(separator: " → "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !file.snippets.isEmpty { Section("Snippets") { ForEach(file.snippets) { Text($0.name) } } }
                if !file.keywords.isEmpty { Section("Search keywords") { ForEach(file.keywords) { Text($0.keyword + " · " + $0.template) } } }
                if !file.aliases.isEmpty { Section("App aliases") { ForEach(file.aliases.keys.sorted(), id: \.self) { Text($0) } } }
            }
            if pending.skipped > 0 {
                Text("\(pending.skipped) items are skipped because you have them already or they are not valid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { confirm(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }
}

/// An empty list's message with a button that opens a filled-in example for the user to check and save.
private struct ExampleRow: View {
    let text: String
    let example: String
    let action: () -> Void
    var body: some View {
        HStack {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Button(example + "…", action: action).controlSize(.small)
        }
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
