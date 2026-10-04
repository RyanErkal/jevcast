import SwiftUI
import LauncherCore

struct RunContentVersion: Hashable {
    let id: String
    let state: String
    let outputFile: String?
    let journalFile: String?
    let finished: Date?
    init(_ run: RunRecord) {
        id = run.id; state = run.state.rawValue; outputFile = run.outputFile
        journalFile = run.journalFile; finished = run.finished
    }
}

/// Needs You, Running, Failed, and History: runs on the left, the chosen run on the right.
struct RunListSplit: View {
    @ObservedObject var model: AutomationsViewModel
    let section: AutomationsViewModel.Section

    var body: some View {
        let runs = model.runs(in: section)
        // With nothing to list, one full-width message; a second "nothing selected" pane adds nothing.
        if runs.isEmpty {
            empty
        } else {
            let selected = model.selectedRun.flatMap { run in runs.contains(where: { $0.id == run.id }) ? run : nil }
            ResponsiveSplit(selection: selected?.id, listTitle: section.title) { openDetail in
                List(selection: $model.selectedRunID) {
                    StreakRows(model: model, streaks: model.streaks(in: section), showsName: true, openDetail: openDetail)
                }
                .listStyle(.inset)
            } detail: {
                if let selected {
                    RunScreen(model: model, run: selected).id(selected.id)
                } else {
                    EmptyStateView(symbol: "doc.text.magnifyingglass", title: "No run selected", message: "Choose a run to see what happened.")
                }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        switch section {
        case _ where !model.search.trimmingCharacters(in: .whitespaces).isEmpty:
            EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "No run matches “\(model.search)”.",
                           actionTitle: "Clear Search") { model.search = "" }
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
                    StreakRows(model: model, streaks: model.streaks(for: automation.id), showsName: false)
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

/// Runs as list rows, a repeated failure as one row with its count. The row's disclosure button (or its
/// context menu) lists every run of the streak; each stays selectable, and none is removed from the store.
struct StreakRows: View {
    @ObservedObject var model: AutomationsViewModel
    let streaks: [RunStreak]
    let showsName: Bool
    var openDetail: () -> Void = {}
    @State private var expanded: Set<String> = []

    var body: some View {
        ForEach(streaks) { streak in
            let open = expanded.contains(streak.id)
            RunRow(model: model, run: streak.latest, showsName: showsName, streak: streak.count > 1 ? streak : nil,
                   expanded: open, toggle: { toggle(streak.id) }, openDetail: openDetail)
                .tag(streak.latest.id)
                .contextMenu {
                    if streak.count > 1 {
                        Button(open ? "Hide Earlier Runs" : "Show All \(streak.count) Runs") { toggle(streak.id) }
                    }
                }
            if open {
                ForEach(streak.earlier) { run in
                    RunRow(model: model, run: run, showsName: showsName, openDetail: openDetail).padding(.leading, 22).tag(run.id)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

struct RunRow: View {
    @ObservedObject var model: AutomationsViewModel
    let run: RunRecord
    let showsName: Bool
    /// Set when this row stands for a repeated failure.
    var streak: RunStreak?
    var expanded = false
    var toggle: () -> Void = {}
    var openDetail: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            if showsName, let automation = model.automation(run.automationID) {
                SymbolTile(symbol: automation.symbol, tint: AutomationTint.color(for: automation), size: 26)
            } else {
                Image(systemName: run.displaySymbol).foregroundStyle(run.displayTint).frame(width: 18).accessibilityHidden(true)
            }
            // The chip sits under the title, as in automation rows, so a narrow list keeps the name readable.
            VStack(alignment: .leading, spacing: 3) {
                Text(showsName ? run.automationName : (run.started ?? run.queued).formatted(date: .abbreviated, time: .shortened))
                    .font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 5) {
                    StatusChip(run: run)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectedRunID = run.id
                openDetail()
            }
            Spacer(minLength: 6)
            if let streak {
                Button(action: toggle) {
                    HStack(spacing: 3) {
                        Text("\(streak.count)×").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(expanded ? "Hide the earlier runs" : "Show all \(streak.count) runs")
                .accessibilityLabel(expanded ? "Hide the earlier runs" : "Show all \(streak.count) runs with this failure")
            }
        }
        .padding(.vertical, 3)
    }

    private var details: String {
        var parts: [String] = []
        if let streak {
            parts.append("\(streak.count) times since " + streak.since.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        }
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
        case .needsInput: RunQuestionView(model: model, run: run).id(run.questions.last?.round)
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
    @State private var journal: ApplyJournal?
    @State private var undoResult: ApplyJournal?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RunHeader(model: model, run: run)
                let explanation = model.explanation(run)
                if let explanation {
                    ExplainedFailureCard(explanation: explanation, error: run.error)
                } else if let error = run.error, !error.isEmpty {
                    DetailCard(title: "Error", symbol: "xmark.octagon") {
                        Text(error).font(.system(.callout, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if let streak = model.streaks(for: run.automationID).first(where: { $0.runs.contains { $0.id == run.id } }), streak.count > 1 {
                    Label("The same result \(streak.count) times in a row, from "
                          + streak.since.formatted(date: .abbreviated, time: .shortened) + " to "
                          + (streak.latest.started ?? streak.latest.queued).formatted(date: .abbreviated, time: .shortened)
                          + ". Each run is kept in History and in its run folder.", systemImage: "square.stack")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if run.state.isFinished, [.failed, .interrupted, .expired].contains(run.state) {
                    HStack {
                        if explanation?.retryHelps == false {
                            Button { model.runNow(run.automationID) } label: { Label("Run Again", systemImage: "arrow.clockwise") }
                                .help("Runs it again now. It gives the same result until the cause is fixed.")
                        } else {
                            Button { model.runNow(run.automationID) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Open Run Folder") { model.reveal(run) }
                    }
                }
                if let journal {
                    ApplyResultView(journal: journal, undoResult: undoResult) { Task { undoResult = await model.undo(run) } }
                        .frame(minHeight: 240)
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
        .task(id: RunContentVersion(run)) {
            loaded = false
            let text = await model.readOutput(of: run)
            guard !Task.isCancelled else { return }
            output = text; rendered = text.map(MarkdownText.render)
            journal = model.journal(for: run)
            loaded = true
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

/// A failure with a known cause: what happened in plain words, then the saved error as evidence.
struct ExplainedFailureCard: View {
    let explanation: FailureExplanation
    let error: String?

    var body: some View {
        DetailCard(title: explanation.title, symbol: explanation.kind == .needsReview ? "exclamationmark.triangle" : "pause.circle") {
            Text(explanation.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let error, !error.isEmpty {
                Text(error).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(run.automationName).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    StatusChip(run: run)
                }
                Text(AutomationFormat.trigger(run.trigger) + " · " + (run.started ?? run.queued).formatted(date: .abbreviated, time: .shortened))
                    .font(.callout).foregroundStyle(.secondary)
                if !run.summary.isEmpty { Text(run.summary).font(.body).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
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
                        VStack(alignment: .leading) { ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in Button(choice) { send(choice) }.controlSize(.large) } }
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
        sent = model.answer(run, trimmed)
    }
}
