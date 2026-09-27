import SwiftUI
import LauncherCore

/// UI names for the model catalogue in LauncherCore.
enum AgentModels {
    static func displayName(_ id: String, runner: AgentRunner) -> String { AgentModelCatalog.displayName(id, runner: runner) }
    static func isKnown(_ id: String, runner: AgentRunner) -> Bool { AgentModelCatalog.isKnown(id, runner: runner) }
}

/// Provider, model, reasoning effort, and speed, shown the same way in the editor and in Settings.
/// An unknown stored model stays selected as "Custom: <id>" until the user picks another.
struct AgentProviderFields: View {
    @Binding var runner: AgentRunner
    @Binding var model: String
    @Binding var effort: ReasoningEffort
    @Binding var fast: Bool
    /// Called after the provider changes, so the caller can pick that provider's model.
    var onProviderChange: ((AgentRunner) -> Void)? = nil

    var body: some View {
        Picker("Provider", selection: providerBinding) {
            Text("ChatGPT (Codex)").tag(AgentRunner.codex)
            Text("Claude").tag(AgentRunner.claude)
        }
        .pickerStyle(.segmented)
        Picker("Model", selection: modelBinding) {
            ForEach(AgentModelCatalog.choices(runner), id: \.self) { Text($0.name).tag($0.id) }
            if let custom = customID { Text("Custom: " + custom).tag(custom) }
        }
        Picker("Reasoning effort", selection: $effort) {
            ForEach(effortChoices, id: \.self) { Text($0.title).tag($0) }
        }
        if AgentModelCatalog.supportsFast(runner) {
            Picker("Speed", selection: $fast) { Text("Normal").tag(false); Text("Fast").tag(true) }
                .pickerStyle(.segmented)
        } else {
            Picker("Speed", selection: .constant(false)) { Text("Normal").tag(false) }
                .pickerStyle(.segmented).disabled(true)
            Text("Only normal speed for now.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var customID: String? {
        let id = AgentModelCatalog.resolved(model, runner: runner)
        return AgentModelCatalog.isKnown(id, runner: runner) ? nil : id
    }

    private var effortChoices: [ReasoningEffort] {
        AgentModelCatalog.efforts.contains(effort) ? AgentModelCatalog.efforts : [effort] + AgentModelCatalog.efforts
    }

    private var modelBinding: Binding<String> {
        Binding(get: { AgentModelCatalog.resolved(model, runner: runner) }, set: { model = $0 })
    }

    private var providerBinding: Binding<AgentRunner> {
        Binding(get: { runner }, set: { new in
            guard new != runner else { return }
            runner = new
            if let onProviderChange { onProviderChange(new) } else { model = AgentModelCatalog.defaultModel(new) }
            if !AgentModelCatalog.supportsFast(new) { fast = false }
        })
    }
}
