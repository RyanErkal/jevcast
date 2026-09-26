import SwiftUI
import LauncherCore

/// Needs You, Running, Failed, and History: runs on the left, the chosen run on the right.
struct RunListSplit: View {
    @ObservedObject var model: AutomationsViewModel
    let section: AutomationsViewModel.Section

    var body: some View {
        let runs = model.runs(in: section)
        HSplitView {
            Group {
                if runs.isEmpty { empty } else {
                    List(selection: $model.selectedRunID) {
                        ForEach(runs) { run in RunRow(model: model, run: run, showsName: true).tag(run.id) }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
            Group {
                if let run = model.selectedRun, runs.contains(where: { $0.id == run.id }) {
                    RunScreen(model: model, run: run).id(run.id)
                } else {
                    EmptyStateView(symbol: "doc.text.magnifyingglass", title: "No run selected", message: "Choose a run to see what happened.")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var empty: some View {
        switch section {
        case .needsYou: EmptyStateView(symbol: "checkmark.seal", title: "All caught up", message: "Questions and changes to approve show here.")
        case .running: EmptyStateView(symbol: "moon.zzz", title: "Nothing running", message: "Runs show here while they work.")
        case .failed: EmptyStateView(symbol: "checkmark.circle", title: "No failures this week", message: "Runs that fail show here for seven days.")
        default: EmptyStateView(symbol: "clock.arrow.circlepath", title: "No runs yet", message: "Run an automation to see its history.",
                                actionTitle: "Show Automations") { model.section = .all }
        }
    }
}

/// The Runs tab of one automation: its history above, the chosen run below.
struct AutomationRunsTab: View {
    @ObservedObject var model: AutomationsViewModel
    let automation: Automation
    @State private var selection: String?

    var body: some View {
        let runs = model.runs(for: automation.id)
        if runs.isEmpty {
            EmptyStateView(symbol: "clock", title: "No runs yet", message: "Run it now to try it, or wait for its schedule.",
                           actionTitle: "Run Now") { model.runNow(automation.id) }
        } else {
            VSplitView {
                List(selection: $selection) {
                    ForEach(runs) { run in RunRow(model: model, run: run, showsName: false).tag(run.id) }
                }
                .listStyle(.inset)
                .frame(minHeight: 120, idealHeight: 200)
                Group {
                    if let run = runs.first(where: { $0.id == selection }) { RunScreen(model: model, run: run).id(run.id) }
                    else { EmptyStateView(symbol: "doc.text", title: "Choose a run", message: "Its output, questions, and usage show here.") }
                }
                .frame(minHeight: 220, maxHeight: .infinity)
            }
            .onAppear { if selection == nil { selection = runs.first?.id } }
        }
    }
}

struct RunRow: View {
    @ObservedObject var model: AutomationsViewModel
    let run: RunRecord
    let showsName: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsName, let automation = model.automation(run.automationID) {
                SymbolTile(symbol: automation.symbol, tint: AutomationTint.color(automation.id), size: 26)
            } else {
                Image(systemName: run.state.symbol).foregroundStyle(run.state.tint).frame(width: 18).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(showsName ? run.automationName : (run.started ?? run.queued).formatted(date: .abbreviated, time: .shortened))
                    .font(.body.weight(.medium)).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            StatusChip(run.state)
        }
        .padding(.vertical, 3)
    }

    private var details: String {
        var parts: [String] = []
        if showsName { parts.append(AutomationFormat.relative(run.started ?? run.queued)) }
        parts.append(AutomationFormat.trigger(run.trigger))
        if let d = run.duration { parts.append(AutomationFormat.duration(d)) }
        if let usage = run.usage { parts.append(AutomationFormat.tokens(usage)) }
        if !run.summary.isEmpty { parts.append(run.summary) }
        return parts.joined(separator: " · ")
    }
}

/// Picks the right screen for a run's state.
struct RunScreen: View {
    @ObservedObject var model: AutomationsViewModel
    let run: RunRecord
    var body: some View {
        switch run.state {
        case .needsApproval: ApprovalView(model: model, run: run)
        case .needsInput: RunQuestionView(model: model, run: run)
        default: RunDetailView(model: model, run: run)
        }
    }
}

/// A run's header, summary, error, output, questions, and usage.
struct RunDetailView: View {
    @ObservedObject var model: AutomationsViewModel
    let run: RunRecord
    @State private var output: String?
    @State private var rendered: AttributedString?
    @State private var raw = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RunHeader(model: model, run: run)
                if let error = run.error, !error.isEmpty {
                    DetailCard(title: "Error", symbol: "xmark.octagon") {
                        Text(error).font(.system(.callout, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if run.state.isFinished, [.failed, .interrupted, .expired].contains(run.state) {
                    HStack {
                        Button { model.runNow(run.automationID) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                            .buttonStyle(.borderedProminent)
                        Button("Open Run Folder") { model.reveal(run) }
                    }
                }
                outputCard
                if !run.questions.isEmpty {
                    DetailCard(title: "Questions and answers", symbol: "questionmark.bubble") {
                        ForEach(run.questions, id: \.round) { q in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(q.text).font(.callout.weight(.medium))
                                Text(q.answer ?? "Not answered").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                DetailCard(title: "Usage", symbol: "gauge.with.dots.needle.33percent") {
                    FactRow(label: "Started", value: run.started?.formatted(date: .abbreviated, time: .standard) ?? "Not yet")
                    FactRow(label: "Duration", value: AutomationFormat.duration(run.duration))
                    FactRow(label: "Attempt", value: "\(run.attempt)")
                    if let code = run.exitCode { FactRow(label: "Exit status", value: "\(code)") }
                    if let usage = run.usage {
                        FactRow(label: "Tokens", value: "\(usage.input.formatted()) in (\(usage.cachedInput.formatted()) cached) · \(usage.output.formatted()) out")
                    } else { FactRow(label: "Tokens", value: "Unknown") }
                }
            }
            .padding(20)
        }
        .task(id: run.id) {
            // Read and parse once per run, not on every redraw.
            let text = model.output(of: run)
            output = text; rendered = text.map(MarkdownText.render); loaded = true
        }
    }

    @ViewBuilder private var outputCard: some View {
        DetailCard(title: "Output", symbol: "doc.plaintext") {
            if let output, !output.isEmpty {
                HStack {
                    Toggle("Raw", isOn: $raw).toggleStyle(.switch).controlSize(.mini)
                    Spacer()
                    Button { copyText(output) } label: { Label("Copy Output", systemImage: "doc.on.doc") }.controlSize(.small)
                }
                Group {
                    if raw || rendered == nil { Text(output).font(.system(.callout, design: .monospaced)) }
                    else { Text(rendered ?? AttributedString(output)).font(.callout) }
                }
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(loaded ? (run.state.isActive ? "Output shows when the run finishes." : "No output was saved.") : "Loading…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct RunHeader: View {
    @ObservedObject var model: AutomationsViewModel
    let run: RunRecord
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(run.automationName).font(.title3.weight(.semibold))
                    StatusChip(run.state)
                }
                Text(AutomationFormat.trigger(run.trigger) + " · " + (run.started ?? run.queued).formatted(date: .abbreviated, time: .shortened))
                    .font(.callout).foregroundStyle(.secondary)
                if !run.summary.isEmpty { Text(run.summary).font(.body) }
            }
            Spacer()
            if run.state.isActive || run.state.needsUser {
                Button("Cancel Run", role: .destructive) { model.cancel(run) }
            }
            Button { model.reveal(run) } label: { Image(systemName: "folder") }
                .help("Show in Finder").accessibilityLabel("Show run folder in Finder")
        }
    }
}

/// The agent asked a question. Choices become buttons; otherwise a text answer.
struct RunQuestionView: View {
    @ObservedObject var model: AutomationsViewModel
    let run: RunRecord
    @State private var answer = ""
    @State private var sent = false

    var body: some View {
        let question = run.questions.last { $0.answer == nil } ?? run.questions.last
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RunHeader(model: model, run: run)
                DetailCard(title: "The agent asks", symbol: "questionmark.bubble") {
                    Text(question?.text ?? "The question could not be read.").font(.title3).textSelection(.enabled)
                    if sent {
                        Label("Answer sent. The run continues in the background.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let choices = question?.choices, !choices.isEmpty {
                        HStack { ForEach(choices, id: \.self) { choice in Button(choice) { send(choice) }.controlSize(.large) } }
                    } else {
                        TextField("Your answer", text: $answer, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(3...8)
                            .onSubmit { send(answer) }
                        HStack {
                            Spacer()
                            Button("Send Answer") { send(answer) }.buttonStyle(.borderedProminent)
                                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                Text("An answer only guides the agent. It cannot give it new folders or approve changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sent else { return }
        sent = true
        model.answer(run, trimmed)
    }
}
