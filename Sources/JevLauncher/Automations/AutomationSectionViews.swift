import SwiftUI
import LauncherCore

/// Codex automations, read only, with a paused import.
struct CodexSectionView: View {
    @ObservedObject var model: AutomationsViewModel

    var body: some View {
        if model.codex.isEmpty {
            EmptyStateView(symbol: "chevron.left.forwardslash.chevron.right", title: "No Codex automations",
                           message: "Automations you make in the Codex app show here, read only, so you can bring them into Jevcast.")
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

/// Client metrics cards, read from the configured sidecars.
struct ClientsSectionView: View {
    @ObservedObject var model: AutomationsViewModel

    var body: some View {
        if model.clients.isEmpty {
            EmptyStateView(symbol: "chart.bar.xaxis", title: "No clients yet",
                           message: "Add a client's metrics file in Settings › Automations to see its numbers and freshness here.")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(model.clients) { ClientCard(model: model, entry: $0) }
                }
                .padding(20)
            }
        }
    }
}

struct ClientCard: View {
    @ObservedObject var model: AutomationsViewModel
    let entry: AutomationCenter.ClientEntry

    var body: some View {
        let snap = entry.snapshot
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.config.name).font(.title3.weight(.semibold))
                Text(range(snap)).font(.caption).foregroundStyle(.secondary)
            }
            if let sources = snap?.sources, !sources.isEmpty {
                FlowRow(sources.map { s in
                    let f = s.freshness()
                    return (s.name + ": " + label(f), color(f))
                })
            }
            if let kpis = snap?.kpis, !kpis.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)], spacing: 8) {
                    ForEach(kpis, id: \.id) { KpiTile(kpi: $0) }
                }
            }
            let problems = (entry.readError.map { ["Last read failed: " + $0] } ?? []) + (snap?.problems ?? [])
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }
            }
            HStack {
                Button("Open Dashboard") { model.openDashboard(entry.id) }.disabled(entry.config.dashboardPath == nil)
                Button("Refresh Now") { model.refreshClient(entry.id) }.disabled(entry.config.automationID == nil && !model.isDemo)
                Spacer()
                if let read = entry.readAt { Text("Read " + AutomationFormat.relative(read)).font(.caption).foregroundStyle(.tertiary) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private func range(_ snap: ClientMetricsSnapshot?) -> String {
        guard let snap else { return "Not read yet" }
        var parts: [String] = []
        if let a = snap.rangeStart, let b = snap.rangeEnd { parts.append("\(a) to \(b)") }
        if let tz = snap.reportingTimeZone { parts.append(tz) }
        if let g = snap.generatedAt { parts.append("generated " + AutomationFormat.relative(g)) }
        return parts.isEmpty ? "No report range" : parts.joined(separator: " · ")
    }
    private func label(_ f: MetricsFreshness) -> String {
        switch f { case .fresh: return "Fresh"; case .aging: return "Aging"; case .stale: return "Stale"; case .failed: return "Failed"; case .unknown: return "Unknown" }
    }
    private func color(_ f: MetricsFreshness) -> Color {
        switch f { case .fresh: return .green; case .aging: return .orange; case .stale, .failed: return .red; case .unknown: return .gray }
    }
}

/// Chips that wrap onto new lines.
struct FlowRow: View {
    let items: [(String, Color)]
    init(_ items: [(String, Color)]) { self.items = items }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }
    @ViewBuilder private var chips: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            StatusChip(title: item.0, tint: item.1, symbol: "circle.fill")
        }
    }
}

struct KpiTile: View {
    let kpi: ClientMetricsSnapshot.Kpi
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(kpi.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(Self.format(kpi)).font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(kpi.value == nil ? .secondary : .primary)
            if let note = kpi.note { Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Nil is "N/A", never zero.
    static func format(_ kpi: ClientMetricsSnapshot.Kpi) -> String {
        guard let v = kpi.value else { return "N/A" }
        switch kpi.format {
        case .count: return v.formatted(.number.precision(.fractionLength(0)))
        case .currency: return v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 1000 ? 0 : 2)))
        case .percent: return (v / 100).formatted(.percent.precision(.fractionLength(1)))
        case .ratio: return v.formatted(.number.precision(.fractionLength(2)))
        }
    }
}

/// Quill tasks live in their own center; this lists them with the same look.
struct QuillTasksView: View {
    @ObservedObject var model: AutomationsViewModel

    var body: some View {
        if model.quillTasks.isEmpty {
            EmptyStateView(symbol: "text.quote", title: "No Quill tasks",
                           message: "Quill tasks write a brief from your Calendar, Reminders, or unread Mail at a set time.",
                           actionTitle: "New Quill Task") { model.showQuillExplainer = true }
        } else {
            List {
                Section {
                    ForEach(model.quillTasks) { task in QuillTaskRow(model: model, task: task) }
                } footer: {
                    HStack {
                        Text("Quill tasks run inside Jevcast while it is open.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("New Quill Task") { model.showQuillExplainer = true }.controlSize(.small)
                    }
                    .padding(.top, 6)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct QuillTaskRow: View {
    @ObservedObject var model: AutomationsViewModel
    let task: QuillTask

    var body: some View {
        let last = model.quillLastRun(task.id)
        let running = model.quillRunning(task.id)
        HStack(spacing: 10) {
            SymbolTile(symbol: "text.quote", tint: task.enabled ? .orange : .gray, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name).font(.body.weight(.medium))
                Text(details(last)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let last {
                StatusChip(title: last.succeeded ? "Done" : "Failed", tint: last.succeeded ? .green : .red)
                Button("Open Result") { model.openQuillResult(last) }.controlSize(.small)
            }
            Button(running ? "Running…" : "Run Now") { model.runQuill(task) }.controlSize(.small).disabled(running)
            Toggle("", isOn: Binding(get: { task.enabled }, set: { model.setQuillEnabled(task.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel(task.enabled ? "Pause \(task.name)" : "Turn on \(task.name)")
        }
        .padding(.vertical, 4)
    }

    private func details(_ last: QuillTaskRun?) -> String {
        var parts = [task.schedule.summary]
        if !task.contexts.isEmpty { parts.append("reads " + task.contexts.map(\.title).joined(separator: ", ").lowercased()) }
        if let last { parts.append("last run " + AutomationFormat.relative(last.date)) }
        return parts.joined(separator: " · ")
    }
}
