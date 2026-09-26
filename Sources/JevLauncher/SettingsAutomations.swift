import AppKit
import LauncherCore
import SwiftUI

/// Settings › Automations: the background runner, agent defaults, alerts, runs, Codex, and clients.
/// App-only choices are in Preferences; values the runner reads go through `AutomationCenter.saveSettings`.
struct AutomationSettingsPane: View {
    enum Part: String, CaseIterable { case runner = "Runner", agents = "Agents", alerts = "Alerts", clients = "Codex & Clients" }
    @ObservedObject var preferences: Preferences
    @ObservedObject var center: AutomationCenter
    let resized: () -> Void
    @AppStorage("settingsAutomationsPart") private var part: Part = .runner

    var body: some View {
        Form {
            Section { PaneSections(selection: $part) }
            switch part {
            case .runner:
                RunnerSettingsSection(center: center)
                RunSettingsSection(preferences: preferences, center: center)
            case .agents: AgentSettingsSection(preferences: preferences, center: center)
            case .alerts: AlertSettingsSection(preferences: preferences, center: center)
            case .clients:
                CodexSettingsSection(preferences: preferences, center: center)
                ClientSettingsSection(center: center)
            }
            if let message = center.message {
                Section { Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: part) { _, _ in resized() }
    }
}

extension AutomationCenter {
    /// A binding to one runner setting that saves on change.
    func setting<T>(_ keyPath: WritableKeyPath<AutomationSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in
            var s = self.settings; s[keyPath: keyPath] = value; self.saveSettings(s)
        })
    }
}

// MARK: Runner

private struct RunnerSettingsSection: View {
    @ObservedObject var center: AutomationCenter

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(center.runnerStatus.title)
                Spacer()
                switch center.runnerStatus {
                case .off, .failed: Button("Turn On") { center.turnOnRunner() }.controlSize(.small)
                case .unsignedBuild: EmptyView()
                default: Button("Turn Off") { center.turnOffRunner() }.controlSize(.small)
                }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if center.runnerStatus == .needsApproval {
                HStack { Spacer(); Button("Open Login Items") { center.openLoginItems() }.controlSize(.small) }
            }
            if let beat = center.heartbeat {
                LabeledContent("Last heartbeat") {
                    Text(beat.heartbeat.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Background runner") } footer: {
            Text("Runs even when Jevcast is closed. It does not run while you are logged out or the Mac is off; sleep delays it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch center.runnerStatus {
        case .running: return .green
        case .starting, .needsApproval: return .orange
        case .notResponding, .failed: return .red
        case .off, .unsignedBuild: return .secondary
        }
    }

    private var explanation: String {
        switch center.runnerStatus {
        case .unsignedBuild:
            return "This copy is signed ad hoc. macOS runs background helpers only for apps signed with a developer certificate. Build with an Apple Development certificate in your keychain, or install a release."
        case .off: return "Scheduled automations do not run. Run Now waits until you turn it on."
        case .needsApproval: return "macOS needs your permission. Turn on Jevcast in System Settings › General › Login Items."
        case .starting: return "The runner is starting. It checks in within 90 seconds."
        case .running(let since): return "Checking schedules every 30 seconds. Started " + since.formatted(.relative(presentation: .named)) + "."
        case .notResponding: return "It is registered, but it has not checked in for over 90 seconds. Turn it off and on again."
        case .failed: return "The runner could not start. Reinstall Jevcast if this stays."
        }
    }
}

// MARK: Runs

private struct RunSettingsSection: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var center: AutomationCenter
    @State private var confirmDelete = false
    @State private var note = ""
    private let defaultPath = AutomationSettings().scriptPath

    var body: some View {
        Section {
            Picker("Runs at once", selection: center.setting(\.maxConcurrentRuns)) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Stop a run after", selection: $preferences.automationTimeoutMinutes) {
                ForEach(Preferences.automationTimeoutChoices, id: \.self) { Text($0 == 60 ? "1 hour" : "\($0) minutes").tag($0) }
            }
            Picker("Keep history", selection: center.setting(\.historyDays)) {
                Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
            }
            Toggle("Keep Mac awake while running", isOn: center.setting(\.preventIdleSleep))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("PATH for scripts", text: center.setting(\.scriptPath))
                    Button("Reset") { var s = center.settings; s.scriptPath = defaultPath; center.saveSettings(s) }
                        .controlSize(.small).disabled(center.settings.scriptPath == defaultPath)
                }
                Text("Scripts get only this PATH. Jevcast never reads it from a login shell.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Automations Folder") {
                    try? center.store.ensureRoot()
                    NSWorkspace.shared.open(center.store.root)
                }.disabled(center.isolated)
                Spacer()
                Button("Delete Finished History…", role: .destructive) { confirmDelete = true }.disabled(center.isolated)
            }
            .controlSize(.small)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("Runs") } footer: {
            Text("The timeout applies to new automations. Each automation can change it in its editor.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Delete all finished run history?", isPresented: $confirmDelete) {
            Button("Delete History", role: .destructive, action: deleteHistory)
        } message: {
            Text("This deletes the output of every finished run. Runs that wait for you or are active stay. Changes already applied are not undone, but they can no longer be undone from Jevcast.")
        }
    }

    private func deleteHistory() {
        let store = center.store
        Task { @MainActor in
            let removed = await Task.detached { store.removeFinishedRuns() }.value
            note = removed == 1 ? "Deleted 1 run." : "Deleted \(removed) runs."
            center.refresh()
        }
    }
}

// MARK: Agents

private struct AgentSettingsSection: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var center: AutomationCenter

    var body: some View {
        Section {
            Picker("Default runner", selection: $preferences.automationRunner) {
                ForEach(AgentRunner.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if preferences.automationRunner == .codex {
                TextField("Model", text: $preferences.automationCodexModel, prompt: Text("gpt-6-astra"))
            } else {
                TextField("Model", text: $preferences.automationClaudeModel, prompt: Text("opus, or empty for the CLI default"))
            }
            Picker("Reasoning effort", selection: $preferences.automationEffort) {
                ForEach(ReasoningEffort.allCases.filter { $0 != .none }, id: \.self) { Text($0.title).tag($0) }
            }
            if preferences.automationRunner == .codex {
                Toggle("Fast", isOn: $preferences.automationFast)
                Text("Uses more of your ChatGPT quota.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Access", selection: $preferences.automationAccess) {
                ForEach(AgentAccess.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: { Text("Defaults for new agent automations") } footer: {
            InfoCaption("Agent runs use your signed-in subscription.",
                        detail: "Jevcast runs the codex or claude command you are signed in to. It removes API-key variables such as OPENAI_API_KEY and ANTHROPIC_API_KEY, so runs use your ChatGPT or Claude plan, not API billing. The agent reads only the folders you allow and never runs changes itself: file changes wait for your approval.")
        }
        Section("Command-line tools") {
            ToolRow(title: "Codex", tool: center.codexTool, path: center.settings.codexPath) { choose(.codex) }
            ToolRow(title: "Claude", tool: center.claudeTool, path: center.settings.claudePath) { choose(.claude) }
            HStack {
                if center.detectingTools { ProgressView().controlSize(.small) }
                Spacer()
                Button("Detect Again") { center.detectTools() }.controlSize(.small).disabled(center.detectingTools || center.isolated)
            }
        }
    }

    private func choose(_ runner: AgentRunner) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        panel.message = "Choose the \(runner.executableName) program"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        center.chooseTool(runner, path: url.path)
    }
}

private struct ToolRow: View {
    let title: String
    let tool: AutomationCenter.ToolInfo?
    let path: String
    let choose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: choose).controlSize(.small)
        }
    }

    private var detail: String {
        let shown = tool?.path ?? path
        guard !shown.isEmpty else { return "Not found" }
        return (shown as NSString).abbreviatingWithTildeInPath + (tool?.version.map { " · " + $0 } ?? "")
    }
}

// MARK: Alerts

private struct AlertSettingsSection: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var center: AutomationCenter

    var body: some View {
        Section {
            Toggle("Show alerts from the notch", isOn: $preferences.automationAlerts)
            Group {
                Toggle("Alert when a run fails", isOn: $preferences.automationAlertFailures)
                Toggle("Hide automation names in alerts", isOn: $preferences.automationHideNames)
                LabeledContent("Keep alerts up for") {
                    HStack {
                        Slider(value: $preferences.automationAlertSeconds, in: 4...12, step: 1).frame(width: 160)
                            .accessibilityValue("\(Int(preferences.automationAlertSeconds)) seconds")
                        Text("\(Int(preferences.automationAlertSeconds)) s").monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .disabled(!preferences.automationAlerts)
            HStack { Spacer(); Button("Show Test Alert") { center.showTestAlert() }.controlSize(.small) }
        } header: { Text("Alerts") } footer: {
            Text("Questions and changes to approve always alert. Successful runs stay silent in the history unless an automation asks otherwise.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Quiet hours") {
            Toggle("Hold alerts during quiet hours", isOn: $preferences.automationQuietHours)
            Group {
                DatePicker("From", selection: minutes($preferences.automationQuietStart), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minutes($preferences.automationQuietEnd), displayedComponents: .hourAndMinute)
            }
            .disabled(!preferences.automationQuietHours)
            Text("Work still runs. Alerts show when quiet hours end.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Minutes after midnight as a time today, for the time pickers.
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: value.wrappedValue / 60, minute: value.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

// MARK: Codex

private struct CodexSettingsSection: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var center: AutomationCenter

    var body: some View {
        Section {
            Toggle("Show Codex automations", isOn: $preferences.showCodexAutomations)
            LabeledContent("Folder") {
                Text((AutomationCenter.codexFolder.path as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
            }
            LabeledContent("Found") {
                let active = center.codex.filter { $0.status == .active }.count
                Text(center.codex.isEmpty ? "None" : "\(center.codex.count) (\(active) active)").foregroundStyle(.secondary)
            }
        } header: { Text("Codex") } footer: {
            Text("Read only. Jevcast never changes Codex's files. Import a copy in the Automations window; it starts paused.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
