import SwiftUI
import LauncherCore

/// The models offered for each runner. Stored values are the IDs; an empty string means the CLI's default.
enum AgentModels {
    struct Choice: Hashable { let id: String; let name: String }

    static func choices(_ runner: AgentRunner) -> [Choice] {
        switch runner {
        case .codex:
            return [.init(id: "gpt-6-astra", name: "GPT-6 Astra"), .init(id: "gpt-6-sol", name: "GPT-6 Sol"),
                    .init(id: "gpt-6-luna", name: "GPT-6 Luna")]
        case .claude:
            return [.init(id: "opus", name: "Opus"), .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "fable", name: "Fable"), .init(id: "haiku", name: "Haiku")]
        }
    }

    /// A name to show for a stored ID: the display name when known, "CLI default" when empty, else the ID.
    static func displayName(_ id: String, runner: AgentRunner) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "CLI default" }
        return choices(runner).first { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }?.name ?? trimmed
    }

    static func isKnown(_ id: String, runner: AgentRunner) -> Bool {
        choices(runner).contains { $0.id == id }
    }
}

/// A model menu with "CLI default", the runner's models, and "Other…", which shows a text field for any ID.
struct AgentModelPicker: View {
    var title = "Model"
    let runner: AgentRunner
    @Binding var model: String
    @State private var other = false

    private static let otherTag = "\u{0}other"

    var body: some View {
        Picker(title, selection: selection) {
            Text("CLI default").tag("")
            Divider()
            ForEach(AgentModels.choices(runner), id: \.self) { Text($0.name).tag($0.id) }
            Divider()
            Text("Other…").tag(Self.otherTag)
        }
        if showsField {
            TextField("Model ID", text: $model, prompt: Text(runner == .codex ? "gpt-6-astra" : "opus"))
                .accessibilityLabel("Model ID")
        }
    }

    private var showsField: Bool { other || (!model.isEmpty && !AgentModels.isKnown(model, runner: runner)) }

    private var selection: Binding<String> {
        Binding(get: { showsField ? Self.otherTag : model },
                set: { value in
                    if value == Self.otherTag { other = true; if AgentModels.isKnown(model, runner: runner) { model = "" } }
                    else { other = false; model = value }
                })
    }
}
