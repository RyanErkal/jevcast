import SwiftUI
import LauncherCore

/// One automation: a header with its main actions, then Overview or Runs.
struct AutomationDetailView: View {
    enum Tab: String, CaseIterable { case overview = "Overview", runs = "Runs" }
    @ObservedObject var model: AutomationsViewModel
    let automation: Automation
    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("View", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220).padding(.bottom, 10)
            Divider()
            switch tab {
            case .overview: AutomationOverview(model: model, automation: automation)
            case .runs: AutomationRunsTab(model: model, automation: automation)
            }
        }
        .onChange(of: automation.id) { _, _ in tab = .overview }
    }

    /// One row when there is room; otherwise the buttons move under the title so nothing is cut off.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) { identity; Spacer(minLength: 10); actions }
            VStack(alignment: .leading, spacing: 10) { identity; HStack { Spacer(minLength: 0); actions } }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 14) {
            SymbolTile(symbol: automation.symbol, tint: automation.enabled ? AutomationTint.color(automation.id) : .gray, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(automation.name).font(.title2.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let last = model.lastRun(automation.id) { StatusChip(last.state) }
                    else { StatusChip(title: "Never run", tint: .secondary) }
                    Text(statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Toggle("On", isOn: Binding(get: { automation.enabled }, set: { model.setEnabled(automation.id, $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(automation.enabled ? "Pause the schedule" : "Turn on the schedule")
                .accessibilityLabel(automation.enabled ? "Pause the schedule" : "Turn on the schedule")
            Button("Edit") { model.edit(automation.id) }
            Menu {
                Button("Test Run") { model.runNow(automation.id, test: true) }
                AutomationMenu(model: model, automation: automation)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More actions")
            Button { model.runNow(automation.id) } label: { Label("Run Now", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
        }
        .fixedSize()
    }

    private var statusLine: String {
        guard automation.enabled else { return "Paused · " + automation.scheduleSummary }
        if let next = model.nextRun(automation.id) { return "Next run " + AutomationFormat.relative(next) }
        return automation.scheduleSummary
    }
}

/// Schedule, what it does, policies, source, and notes.
struct AutomationOverview: View {
    @ObservedObject var model: AutomationsViewModel
    let automation: Automation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sourceWarning
                DetailCard(title: "Schedule", symbol: "calendar") {
                    FactRow(label: "When", value: automation.scheduleSummary)
                    FactRow(label: "Time zone", value: automation.schedule.timeZone)
                    let upcoming = ScheduleText.upcoming(automation.schedule, limit: 5)
                    if !upcoming.isEmpty {
                        FactRow(label: automation.enabled ? "Next runs" : "Next runs if on",
                                value: upcoming.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) }.joined(separator: "\n"))
                    }
                }
                DetailCard(title: "What it does", symbol: "gearshape.2") { kindFacts }
                DetailCard(title: "Policies", symbol: "slider.horizontal.3") {
                    let p = automation.policy
                    FactRow(label: "Time limit", value: AutomationFormat.duration(TimeInterval(p.timeout)))
                    FactRow(label: "Retries", value: p.retries == 0 ? "None" : "\(p.retries)")
                    FactRow(label: "Missed runs", value: p.catchUp.title)
                    FactRow(label: "Alerts", value: alerts(p))
                    FactRow(label: "Keep runs", value: "\(p.keepRuns)")
                    if let lock = p.sharedLock { FactRow(label: "Shared lock", value: lock, mono: true) }
                }
                if !automation.notes.isEmpty {
                    DetailCard(title: "Notes", symbol: "note.text") { Text(automation.notes).font(.callout).textSelection(.enabled) }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private var kindFacts: some View {
        FactRow(label: "Kind", value: automation.kind.title)
        if let script = automation.script {
            FactRow(label: "Command", value: script.commandLine, mono: true)
            FactRow(label: "Program", value: script.executable, mono: true)
            FactRow(label: "Folder", value: AutomationFormat.path(script.workingDirectory))
            if !script.environment.isEmpty { FactRow(label: "Environment", value: script.environment.keys.sorted().joined(separator: ", ")) }
            if !script.secretNames.isEmpty { FactRow(label: "Secrets", value: script.secretNames.joined(separator: ", ")) }
        }
        if let agent = automation.agent {
            if automation.script != nil { Divider(); Text("If the script fails, an agent writes a diagnosis:").font(.caption).foregroundStyle(.secondary) }
            FactRow(label: "Runner", value: agent.runner.title)
            FactRow(label: "Model", value: (agent.model.isEmpty ? "CLI default" : agent.model) + " · " + agent.effort.title + (agent.fast && agent.runner == .codex ? " · Fast" : ""))
            FactRow(label: "Access", value: agent.access.title)
            FactRow(label: "Output", value: agent.output.title)
            FactRow(label: "Folder", value: AutomationFormat.path(agent.workingDirectory))
            if !agent.allowedRoots.isEmpty { FactRow(label: "Allowed folders", value: agent.allowedRoots.map(Paths.display).joined(separator: "\n")) }
            if automation.script == nil {
                Text(agent.prompt).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private var sourceWarning: some View {
        if let source = automation.source {
            let codexItem = model.codex.first { $0.id == source.sourceID }
            let stillActive = codexItem?.status == .active
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: stillActive ? "exclamationmark.triangle.fill" : "arrow.down.doc")
                    .foregroundStyle(stillActive ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Imported from \(source.app == .codex ? "Codex" : "Luna Tasks"): \(source.sourceID)").font(.callout.weight(.medium))
                    if stillActive {
                        Text("This automation is still ACTIVE in Codex. Pause it there before turning this copy on, so it does not run twice.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background((stillActive ? Color.orange : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func alerts(_ p: Policy) -> String {
        switch (p.alertOnFailure, p.alertOnSuccess) {
        case (true, true): return "On failure and success"
        case (true, false): return "On failure"
        case (false, true): return "On success"
        case (false, false): return "Only when it needs you"
        }
    }
}
