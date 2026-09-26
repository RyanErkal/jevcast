import SwiftUI
import LauncherCore

/// All automations on the left, the chosen one on the right.
struct AutomationListSplit: View {
    @ObservedObject var model: AutomationsViewModel

    var body: some View {
        HSplitView {
            list.frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            Group {
                if let automation = model.selectedAutomation {
                    AutomationDetailView(model: model, automation: automation)
                } else {
                    EmptyStateView(symbol: "square.stack.3d.up", title: "No automation selected",
                                   message: "Choose an automation to see its schedule, runs, and settings.")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var list: some View {
        let items = model.filteredAutomations
        if model.automations.isEmpty {
            EmptyStateView(symbol: "wand.and.stars", title: "No automations yet",
                           message: "Automations run a prompt or a script on a schedule, in the background. Start from a template or a blank one.",
                           actionTitle: "New Automation") { model.newAutomation() }
        } else if items.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Nothing matches “\(model.search)”.",
                           actionTitle: "Clear Search") { model.search = "" }
        } else {
            List(selection: $model.selectedAutomationID) {
                ForEach(items) { automation in
                    AutomationRow(model: model, automation: automation)
                        .tag(automation.id)
                        .contextMenu { AutomationMenu(model: model, automation: automation) }
                }
                if !model.problems.isEmpty {
                    Section("Could not read") {
                        ForEach(model.problems.sorted(by: { $0.key < $1.key }), id: \.key) { name, problem in
                            Label { VStack(alignment: .leading) { Text(name); Text(problem).font(.caption).foregroundStyle(.secondary) } }
                                icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct AutomationRow: View {
    @ObservedObject var model: AutomationsViewModel
    let automation: Automation

    var body: some View {
        let last = model.lastRun(automation.id)
        HStack(spacing: 10) {
            SymbolTile(symbol: automation.symbol, tint: automation.enabled ? AutomationTint.color(automation.id) : .gray, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.name).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let last { StatusChip(last.state) }
            Toggle("", isOn: Binding(get: { automation.enabled }, set: { model.setEnabled(automation.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel(automation.enabled ? "Pause \(automation.name)" : "Turn on \(automation.name)")
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        var parts = [automation.scheduleSummary]
        if !automation.enabled { parts.append("Paused") }
        else if let next = model.nextRun(automation.id) { parts.append("next " + AutomationFormat.relative(next)) }
        return parts.joined(separator: " · ")
    }
}

/// Verbs for an automation, shared by the context menu and the detail header's More menu.
struct AutomationMenu: View {
    @ObservedObject var model: AutomationsViewModel
    let automation: Automation
    var body: some View {
        Button("Run Now") { model.runNow(automation.id) }
        Button("Test Run") { model.runNow(automation.id, test: true) }
        Divider()
        Button("Edit…") { model.edit(automation.id) }
        Button("Duplicate") { model.duplicate(automation.id) }
        Button(automation.enabled ? "Pause" : "Resume") { model.setEnabled(automation.id, !automation.enabled) }
        if let last = model.lastRun(automation.id) {
            Button("Show Last Run in Finder") { model.reveal(last) }
        }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingDelete = automation }
    }
}
