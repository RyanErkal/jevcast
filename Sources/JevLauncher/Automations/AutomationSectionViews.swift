import SwiftUI
import LauncherCore

/// Codex automations, read only, with a paused import.
struct CodexSectionView: View {
    @ObservedObject var model: AutomationsViewModel

    var body: some View {
        if model.codex.isEmpty {
            EmptyStateView(symbol: "chevron.left.forwardslash.chevron.right", title: "No Codex automations",
                           message: "Automations you make in the Codex app show here, read only, so you can copy them into Jevcast.",
                           actionTitle: "Check Again") { model.live?.refresh() }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Label("Jevcast only reads these files. Pause an automation in Codex before turning on its copy here.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(model.codex) { item in CodexCard(model: model, item: item) }
                }
                .padding(20)
            }
        }
    }
}

struct CodexCard: View {
    @ObservedObject var model: AutomationsViewModel
    let item: CodexAutomation
    /// Loaded in a task: the center re-reads the source file to check it.
    @State private var issues: [String] = []

    var body: some View {
        let copy = model.importedCopy(of: item)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SymbolTile(symbol: "chevron.left.forwardslash.chevron.right", tint: .gray, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name.isEmpty ? item.id : item.name).font(.headline)
                    Text(schedule).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusChip
                if let copy {
                    Button("Imported: Open") { model.section = .all; model.selectedAutomationID = copy.id }
                } else {
                    Button("Import as Paused Copy") { model.importCodex(item) }.disabled(item.error != nil)
                }
            }
            if let error = item.error {
                Label(error, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
            }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill").font(.callout)
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .task(id: item.id + item.hash) { issues = model.importIssues(item) }
    }

    private var schedule: String {
        let text = item.rrule.hasPrefix("RRULE:") ? String(item.rrule.dropFirst(6)) : item.rrule
        guard let rule = try? RRule(text) else { return item.rrule.isEmpty ? "No schedule" : item.rrule }
        return rule.summary() + " · " + item.id
    }

    @ViewBuilder private var statusChip: some View {
        switch item.status {
        case .active: StatusChip(title: "Active in Codex", tint: .orange, symbol: "bolt.fill")
        case .paused: StatusChip(title: "Paused in Codex", tint: .secondary, symbol: "pause.fill")
        case .other(let s): StatusChip(title: s.isEmpty ? "Unknown" : s, tint: .secondary)
        }
    }
}

/// Scheduled briefs live in their own center; this lists them with the same look.
struct ScheduledBriefsView: View {
    @ObservedObject var model: AutomationsViewModel

    var body: some View {
        if model.scheduledBriefs.isEmpty {
            EmptyStateView(symbol: "text.quote", title: "No scheduled briefs",
                           message: "A scheduled brief summarises your Calendar, Reminders, or unread Mail at a set time.",
                           actionTitle: "New Scheduled Brief") { model.showScheduledBriefExplainer = true }
        } else {
            List {
                Section {
                    ForEach(model.scheduledBriefs) { task in ScheduledBriefRow(model: model, task: task) }
                } footer: {
                    HStack {
                        Text("Scheduled briefs run inside Jevcast while it is open.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("New Scheduled Brief") { model.showScheduledBriefExplainer = true }.controlSize(.small)
                    }
                    .padding(.top, 6)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct ScheduledBriefRow: View {
    @ObservedObject var model: AutomationsViewModel
    let task: ScheduledBrief

    var body: some View {
        let last = model.scheduledBriefLastRun(task.id)
        let running = model.scheduledBriefRunning(task.id)
        HStack(spacing: 10) {
            SymbolTile(symbol: "text.quote", tint: task.enabled ? .orange : .gray, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name).font(.body.weight(.medium))
                Text(details(last)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let last {
                StatusChip(title: last.succeeded ? "Done" : "Failed", tint: last.succeeded ? .green : .red)
                Button("Open Result") { model.openScheduledBriefResult(last) }.controlSize(.small)
            }
            Button(running ? "Running…" : "Run Now") { model.runScheduledBrief(task) }.controlSize(.small).disabled(running)
            Toggle("", isOn: Binding(get: { task.enabled }, set: { model.setScheduledBriefEnabled(task.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel(task.enabled ? "Pause \(task.name)" : "Turn on \(task.name)")
        }
        .padding(.vertical, 4)
    }

    private func details(_ last: ScheduledBriefRun?) -> String {
        var parts = [task.schedule.summary]
        if !task.contexts.isEmpty { parts.append("reads " + task.contexts.map(\.title).joined(separator: ", ").lowercased()) }
        if let last { parts.append("last run " + AutomationFormat.relative(last.date)) }
        return parts.joined(separator: " · ")
    }
}
