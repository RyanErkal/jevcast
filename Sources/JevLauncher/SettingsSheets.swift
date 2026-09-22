import SwiftUI

/// Shared frame for the small add/edit sheets: a grouped form and a
/// Cancel/confirm button row.
private struct SettingsSheet<Content: View>: View {
    let confirmTitle: String
    let canConfirm: Bool
    let confirm: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction).disabled(!canConfirm)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }
}

/// Adds a search keyword, or edits one when `original` is set.
struct KeywordSheet: View {
    let original: Quicklink?
    let existing: [Quicklink]
    let save: (Quicklink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keyword: String
    @State private var name: String
    @State private var template: String
    @State private var error = ""

    init(original: Quicklink?, existing: [Quicklink], save: @escaping (Quicklink) -> Void) {
        self.original = original; self.existing = existing; self.save = save
        _keyword = State(initialValue: original?.keyword ?? "")
        _name = State(initialValue: original?.name ?? "")
        _template = State(initialValue: original?.template ?? "")
    }
    var body: some View {
        SettingsSheet(confirmTitle: original == nil ? "Add" : "Save", canConfirm: !trimmed(keyword).isEmpty && !trimmed(template).isEmpty, confirm: commit) {
            Section {
                TextField("Keyword", text: $keyword, prompt: Text("gh"))
                TextField("Name", text: $name, prompt: Text("GitHub"))
                TextField("URL template", text: $template, prompt: Text("https://github.com/search?q={query}"))
            } footer: {
                Text(error.isEmpty ? "{query} marks where the search text goes." : error)
                    .font(.caption).foregroundStyle(error.isEmpty ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func commit() {
        let word = trimmed(keyword), url = trimmed(template), title = trimmed(name)
        let others = existing.filter { $0.id != original?.id }
        if let message = Quicklink.validationError(keyword: word, template: url, existing: others) { error = message; return }
        save(Quicklink(keyword: word, name: title.isEmpty ? word : title, template: url))
        dismiss()
    }
}

/// Adds an app alias.
struct AliasSheet: View {
    let apps: [AppEntry]
    let save: (_ alias: String, _ appID: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var appID = ""
    var body: some View {
        SettingsSheet(confirmTitle: "Add", canConfirm: !trimmedAlias.isEmpty && !appID.isEmpty, confirm: commit) {
            Section {
                TextField("Alias", text: $alias, prompt: Text("coding app"))
                Picker("App", selection: $appID) {
                    Text("Choose an app").tag("")
                    ForEach(apps) { app in Text(app.name).tag(app.id) }
                }
            } footer: {
                Text("Type the alias in the launcher to open the app.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var trimmedAlias: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func commit() {
        save(trimmedAlias, appID)
        dismiss()
    }
}
