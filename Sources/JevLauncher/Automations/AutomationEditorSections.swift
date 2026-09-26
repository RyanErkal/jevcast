import SwiftUI
import LauncherCore

struct EditorBasics: View {
    @Binding var draft: AutomationDraft
    var body: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("Desktop tidy"))
            LabeledContent("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 12), spacing: 6) {
                    ForEach(AutomationSymbols.all, id: \.self) { symbol in
                        Button { draft.symbol = symbol } label: {
                            Image(systemName: symbol).font(.system(size: 13))
                                .frame(width: 28, height: 28)
                                .foregroundStyle(draft.symbol == symbol ? Color.white : Color.primary)
                                .background(draft.symbol == symbol ? Color.accentColor : Color.secondary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel(symbol)
                    }
                }
            }
            Picker("Kind", selection: $draft.kind) {
                ForEach(AutomationDraft.KindChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(kindHelp).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var kindHelp: String {
        switch draft.kind {
        case .agent: return "An agent runs your prompt with Codex or Claude, signed in on this Mac."
        case .script: return "Runs a program you choose, with fixed arguments. Nothing a model writes is ever run."
        case .scriptWithDiagnosis: return "Runs the script. Only when it fails, an agent reads the output and writes a short diagnosis."
        }
    }
}

struct EditorAgent: View {
    @Binding var draft: AutomationDraft
    var body: some View {
        let diagnosis = draft.kind == .scriptWithDiagnosis
        Section(diagnosis ? "Diagnosis when the script fails" : "Agent") {
            Picker("Runner", selection: $draft.runner) { ForEach(AgentRunner.allCases, id: \.self) { Text($0.title).tag($0) } }
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    TextField("Model", text: $draft.model, prompt: Text("CLI default")).labelsHidden()
                    Menu {
                        Button("CLI default") { draft.model = "" }
                        Divider()
                        ForEach(AutomationModels.suggestions(draft.runner), id: \.self) { m in Button(m) { draft.model = m } }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Model suggestions")
                }
            }
            Picker("Reasoning", selection: $draft.effort) {
                ForEach(ReasoningEffort.allCases.filter { $0 != .none }, id: \.self) { Text($0.title).tag($0) }
            }
            if draft.runner == .codex { Toggle("Fast", isOn: $draft.fast) }
            VStack(alignment: .leading, spacing: 6) {
                Text(diagnosis ? "Diagnosis prompt (optional)" : "Prompt")
                TextEditor(text: $draft.prompt)
                    .font(.system(.body, design: .monospaced)).frame(minHeight: 110)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .overlay(alignment: .topLeading) {
                        if draft.prompt.isEmpty {
                            Text(diagnosis ? AutomationDraft.defaultDiagnosisPrompt : "What should it do each time?")
                                .foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                        }
                    }
            }
            if !diagnosis { access }
        }
    }

    @ViewBuilder private var access: some View {
        Picker("Output", selection: $draft.output) { ForEach(OutputMode.allCases, id: \.self) { Text($0.title).tag($0) } }
        Text(outputHelp).font(.caption).foregroundStyle(.secondary)
        Picker("Access", selection: $draft.access) { ForEach(AgentAccess.allCases, id: \.self) { Text($0.title).tag($0) } }
        if draft.access.canWrite {
            Label(draft.access.usesNetwork ? "It can change files in its folder and reach the internet. Use it only for trusted prompts."
                                           : "It can change files in its working folder and allowed folders.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
        PathField(title: "Working folder", path: $draft.agentFolder)
        AllowedFoldersField(roots: $draft.allowedRoots, required: draft.output == .proposal)
    }

    private var outputHelp: String {
        switch draft.output {
        case .report: return "Writes a report you can read in its run."
        case .proposal: return "Suggests file changes. Nothing changes until you approve each one."
        case .ask: return "Writes a report, and may stop to ask you a question first."
        }
    }
}

struct AllowedFoldersField: View {
    @Binding var roots: [String]
    let required: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Allowed folders")
                if required { Text("Required for changes to approve").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Choose…") { if let p = PathPicker.choose(directories: true), !roots.contains(p) { roots.append(p) } }
            }
            ForEach(roots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(root).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button { roots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Remove \(root)")
                }
            }
            HStack(spacing: 6) {
                ForEach(["~/Desktop", "~/Downloads", "~/Documents"].filter { !roots.contains($0) }, id: \.self) { quick in
                    Button { roots.append(quick) } label: { Label(String(quick.dropFirst(2)), systemImage: "plus") }
                        .controlSize(.small).buttonBorderShape(.capsule)
                }
            }
        }
    }
}

struct EditorScript: View {
    @Binding var draft: AutomationDraft
    var body: some View {
        Section("Script") {
            PathField(title: "Program", path: $draft.program, directories: false, prompt: "/opt/homebrew/bin/bun")
            VStack(alignment: .leading, spacing: 6) {
                Text("Arguments, one per line")
                TextEditor(text: $draft.argumentsText)
                    .font(.system(.body, design: .monospaced)).frame(minHeight: 60)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                if !draft.commandLinePreview.isEmpty {
                    Text("Runs:  " + draft.commandLinePreview).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            PathField(title: "Working folder", path: $draft.scriptFolder)
            EnvironmentField(pairs: $draft.environment)
            SecretNamesField(names: $draft.secretNames)
            TextField("Shared lock", text: $draft.sharedLock, prompt: Text("Optional, such as docs-metrics"))
        }
    }
}

struct EnvironmentField: View {
    @Binding var pairs: [AutomationDraft.EnvPair]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Environment")
                Spacer()
                Button { pairs.append(.init(key: "", value: "")) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).accessibilityLabel("Add environment value")
            }
            ForEach($pairs) { $pair in
                HStack(spacing: 6) {
                    TextField("NAME", text: $pair.key).font(.system(.callout, design: .monospaced)).frame(width: 160)
                    Text("=").foregroundStyle(.secondary)
                    TextField("value", text: $pair.value).font(.system(.callout, design: .monospaced))
                    Button { pairs.removeAll { $0.id == pair.id } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Remove \(pair.key)")
                }
            }
        }
    }
}

/// Secret names only. Values belong in the Keychain.
// HOOK(secrets): `AutomationSecrets.save(name:value:)` is not in this branch yet. When it lands, add a
// SecureField per name here and call it on Save; never store the value in the automation.
struct SecretNamesField: View {
    @Binding var names: [String]
    @State private var newName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secrets")
            ForEach(names, id: \.self) { name in
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text(name).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button { names.removeAll { $0 == name } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Remove \(name)")
                }
            }
            HStack(spacing: 6) {
                TextField("NAME", text: $newName).font(.system(.callout, design: .monospaced)).onSubmit(add)
                Button("Add", action: add).disabled(!AutomationDraft.isEnvName(newName) || names.contains(newName))
            }
            Text("Passed to this script only, as environment values. Values are kept in the Keychain, never in the automation file.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func add() {
        guard AutomationDraft.isEnvName(newName), !names.contains(newName) else { return }
        names.append(newName); newName = ""
    }
}

struct EditorSchedule: View {
    @Binding var schedule: ScheduleDraft
    var body: some View {
        Section("Schedule") {
            Picker("Repeat", selection: $schedule.preset) {
                ForEach(ScheduleDraft.Preset.allCases) { Text($0.title).tag($0) }
            }
            switch schedule.preset {
            case .manual:
                Text("Runs only when you click Run Now.").font(.callout).foregroundStyle(.secondary)
            case .everyHours:
                Stepper("Every \(schedule.intervalHours) hour\(schedule.intervalHours == 1 ? "" : "s")", value: $schedule.intervalHours, in: 1...168)
            case .daily, .weekdays:
                time
            case .weekly:
                LabeledContent("Days") { days }
                time
            case .once:
                DatePicker("At", selection: $schedule.onceDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            case .custom:
                TextField("RRULE", text: $schedule.customText, prompt: Text("FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=9;BYMINUTE=0"))
                    .font(.system(.body, design: .monospaced))
            }
            if schedule.preset != .manual {
                Picker("Time zone", selection: $schedule.timeZone) {
                    ForEach(TimeZoneList.all, id: \.self) { Text($0).tag($0) }
                }
            }
            preview
        }
    }

    private var time: some View {
        DatePicker("At", selection: Binding(get: {
            Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            schedule.hour = parts.hour ?? 0; schedule.minute = parts.minute ?? 0
        }), displayedComponents: .hourAndMinute)
    }

    private var days: some View {
        HStack(spacing: 4) {
            ForEach(ScheduleDraft.weekdayOrder, id: \.self) { day in
                let on = schedule.weekdays.contains(day)
                Button { if on { schedule.weekdays.remove(day) } else { schedule.weekdays.insert(day) } } label: {
                    Text(ScheduleDraft.shortNames[day] ?? "").font(.caption.weight(.medium)).frame(width: 34, height: 22)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch schedule.rule() {
        case .failure(let problem):
            Label(problem.message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        case .success:
            LabeledContent("Summary", value: schedule.summary)
            let next = schedule.upcoming(3)
            if !next.isEmpty {
                LabeledContent("Next") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(next, id: \.self) { Text($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())) }
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }
}

enum TimeZoneList {
    static let all: [String] = {
        var list = TimeZone.knownTimeZoneIdentifiers.sorted()
        if !list.contains(TimeZone.current.identifier) { list.insert(TimeZone.current.identifier, at: 0) }
        return list
    }()
}

struct EditorBehaviour: View {
    @Binding var draft: AutomationDraft
    var body: some View {
        Section("Behaviour") {
            Stepper("Time limit: \(draft.policy.timeout / 60) min", value: Binding(get: { draft.policy.timeout / 60 },
                                                                                   set: { draft.policy.timeout = max(1, $0) * 60 }), in: 1...240)
            Stepper("Retries after a failure: \(draft.policy.retries)", value: $draft.policy.retries, in: 0...5)
            Picker("Missed runs", selection: $draft.policy.catchUp) { ForEach(CatchUp.allCases, id: \.self) { Text($0.title).tag($0) } }
            Toggle("Alert when it fails", isOn: $draft.policy.alertOnFailure)
            Toggle("Alert when it succeeds", isOn: $draft.policy.alertOnSuccess)
            Stepper("Keep the last \(draft.policy.keepRuns) runs", value: $draft.policy.keepRuns, in: 5...500, step: 5)
            TextField("Notes", text: $draft.notes, prompt: Text("Optional"), axis: .vertical).lineLimit(1...4)
        }
    }
}
