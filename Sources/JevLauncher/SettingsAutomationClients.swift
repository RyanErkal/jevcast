import AppKit
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Automations › Clients: the metrics sidecars the launcher and Automations window show.
struct ClientSettingsSection: View {
    @ObservedObject var center: AutomationCenter
    @State private var editing: AutomationCenter.ClientConfig?

    var body: some View {
        Section {
            if center.clients.isEmpty { Text("No clients").foregroundStyle(.secondary) }
            ForEach(center.clients) { entry in
                HStack(spacing: 8) {
                    Image(systemName: ClientMetricsText.symbol(entry)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.config.name)
                        Text(status(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Edit…") { editing = entry.config }.controlSize(.small)
                    RemoveButton(label: "Remove " + entry.config.name) { center.removeClient(entry.id) }
                }
            }
            HStack {
                AddButton(title: "Add client…") {
                    editing = .init(id: "client-" + String(UUID().uuidString.prefix(6)).lowercased(), name: "", profile: .generic, metricsPath: "")
                }
                Spacer()
            }
        } header: { Text("Clients") } footer: {
            Text("Jevcast reads each metrics file on this Mac. Showing metrics never opens the dashboard or goes online.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { config in
            ClientEditor(config: config, automations: center.automations) { saved in
                center.saveClient(saved)
                editing = nil
            } cancel: { editing = nil }
        }
    }

    private func status(_ entry: AutomationCenter.ClientEntry) -> String {
        var parts = [entry.config.profile.clientName, (entry.config.metricsPath as NSString).abbreviatingWithTildeInPath]
        if let error = entry.readError { parts.insert(error, at: 0) }
        else if let snapshot = entry.snapshot {
            parts.insert(snapshot.problems.isEmpty ? ClientMetricsText.freshnessText(snapshot) : snapshot.problems[0], at: 0)
        }
        return parts.joined(separator: " · ")
    }
}

private struct ClientEditor: View {
    @State var config: AutomationCenter.ClientConfig
    let automations: [Automation]
    let save: (AutomationCenter.ClientConfig) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $config.name)
                Picker("Metrics format", selection: $config.profile) {
                    ForEach(ClientMetricsProfile.allCases, id: \.self) { Text($0 == .generic ? "Other (schema only)" : $0.clientName).tag($0) }
                }
                FileChooserRow(title: "Metrics file", path: config.metricsPath, types: ["json"]) { config.metricsPath = $0 }
                FileChooserRow(title: "Dashboard", path: config.dashboardPath ?? "", types: ["html"]) { config.dashboardPath = $0 }
                Picker("Refresh automation", selection: $config.automationID) {
                    Text("None").tag(String?.none)
                    ForEach(automations) { Text($0.name).tag(Optional($0.id)) }
                }
                Text("Refresh Now queues this automation. KPI names come from the metrics format and are shown as written.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(config) }.keyboardShortcut(.defaultAction)
                    .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty || config.metricsPath.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480)
    }
}

private struct FileChooserRow: View {
    let title: String
    let path: String
    let types: [String]
    let chosen: (String) -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.isEmpty ? "None" : (path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose…", action: choose).controlSize(.small)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosen(url.path)
    }
}
