import AppKit
import SwiftUI
import LauncherCore

/// New and edit, one form. Save stays off, with the reason shown, until the automation is valid.
struct AutomationEditorView: View {
    @ObservedObject var model: AutomationsViewModel
    @State var draft: AutomationDraft
    let dismiss: () -> Void
    /// Whether the script's program is an executable file, checked after typing stops, never while drawing.
    @State private var programOK = false
    @State private var saveError: String?

    var body: some View {
        let problems = draft.problems(isExecutable: { _ in programOK })
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(symbol: draft.symbol, tint: .accentColor, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.isNew ? "New Automation" : "Edit Automation").font(.headline)
                    Text(draft.name.isEmpty ? "Untitled" : draft.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            Form {
                EditorBasics(draft: $draft)
                if draft.usesScript { EditorScript(draft: $draft) }
                if draft.usesAgent { EditorAgent(draft: $draft) }
                EditorSchedule(schedule: $draft.schedule)
                EditorBehaviour(draft: $draft)
            }
            .formStyle(.grouped)
            Divider()
            footer(problems)
        }
        .frame(width: 700, height: 760)
        .task(id: draft.program) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let path = Paths.expand(draft.program)
            programOK = await Task.detached { FileManager.default.isExecutableFile(atPath: path) }.value
        }
    }

    private func footer(_ problems: [String]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let saveError {
                Label(saveError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).lineLimit(2)
            } else if let first = problems.first {
                Label(first + (problems.count > 1 ? "  (+\(problems.count - 1) more)" : ""), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange).font(.callout).lineLimit(2)
                    .help(problems.joined(separator: "\n"))
            } else if draft.isNew {
                Toggle("Turn on after saving", isOn: $draft.enableAfterSaving).toggleStyle(.checkbox)
            }
            Spacer()
            Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            Button(draft.isNew ? "Save" : "Save Changes") {
                saveError = model.save(draft, isExecutable: { _ in programOK })
                if saveError == nil { dismiss() }
            }
            .keyboardShortcut(.defaultAction).disabled(!problems.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// A path with a Choose… button.
struct PathField: View {
    let title: String
    @Binding var path: String
    var directories = true
    var prompt = "~/Folder"
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: $path, prompt: Text(prompt)).labelsHidden()
                    .font(.system(.body, design: .monospaced))
                Button("Choose…") { if let chosen = PathPicker.choose(directories: directories, start: path) { path = chosen } }
            }
        }
    }
}

enum PathPicker {
    @MainActor static func choose(directories: Bool, start: String = "") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories; panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = directories
        panel.treatsFilePackagesAsDirectories = !directories
        if !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: Paths.expand(start)) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Paths.display(url.path)
    }
}
