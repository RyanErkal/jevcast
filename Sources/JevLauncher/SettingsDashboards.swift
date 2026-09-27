import AppKit
import LauncherCore
import SwiftUI

/// Settings › Automations › Dashboards: the cards the launcher and the Automations window show.
struct DashboardSettingsSection: View {
    @ObservedObject var center: AutomationCenter
    @State private var editing: DashboardConfig?

    var body: some View {
        Section {
            if center.dashboards.isEmpty { Text("No dashboards").foregroundStyle(.secondary) }
            ForEach(center.dashboards) { entry in
                HStack(spacing: 8) {
                    Image(systemName: DashboardDisplay.symbol(entry)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.config.name)
                        Text(status(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Edit…") { editing = entry.config }.controlSize(.small)
                    RemoveButton(label: "Remove " + entry.config.name) { center.removeDashboard(entry.id) }
                }
            }
            HStack {
                AddButton(title: "Add dashboard…") { editing = DashboardConfig.new() }
                Spacer()
            }
        } header: { Text("Dashboards") } footer: {
            Text("Each dashboard reads a JSON file on this Mac. Showing it never opens the file or goes online.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { config in
            DashboardEditor(config: config, automations: center.automations) { saved in
                center.saveDashboard(saved)
                editing = nil
            } cancel: { editing = nil }
        }
    }

    private func status(_ entry: AutomationCenter.DashboardEntry) -> String {
        var parts = ["\(entry.config.metrics.count) value" + (entry.config.metrics.count == 1 ? "" : "s"),
                     (entry.config.filePath as NSString).abbreviatingWithTildeInPath]
        if let problem = DashboardDisplay.problem(entry) { parts.insert(problem, at: 0) }
        return parts.joined(separator: " · ")
    }
}
