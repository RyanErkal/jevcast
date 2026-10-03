import SwiftUI
import LauncherCore

struct EditorBasics: View {
    @Binding var draft: AutomationDraft
    var body: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("Desktop tidy"))
            EditorAppearance(draft: $draft)
            if draft.staged == nil {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(AutomationDraft.KindChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } else {
                LabeledContent("Kind", value: "Report workflow")
            }
        } footer: {
            Text(kindHelp).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var kindHelp: String {
        if draft.staged != nil {
            return "Its stages come from a reviewed definition file. Run jevcast-runner --configure to change them; here you change only the name, icon, colour, schedule, and behaviour."
        }
        switch draft.kind {
        case .agent: return "An agent runs your prompt with Codex or Claude, signed in on this Mac."
        case .script: return "Runs a program you choose, with fixed arguments. Nothing a model writes is ever run."
        case .scriptWithDiagnosis: return "Runs the script. Only when it fails, an agent reads the output and writes a short diagnosis."
        }
    }
}

/// The icon and its colour, as rows and the notch show them. The colour is identity only; states keep their own colours.
struct EditorAppearance: View {
    @Binding var draft: AutomationDraft
    @State private var other = ""

    var body: some View {
        let tint = AutomationTint.color(draft.accent)
        LabeledContent("Icon") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 12), spacing: 6) {
                    ForEach(symbols, id: \.self) { symbol in
                        let selected = draft.symbol == symbol
                        Button { draft.symbol = symbol } label: {
                            Image(systemName: symbol).font(.system(size: 13))
                                .frame(width: 28, height: 28)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.secondary.opacity(0.1)),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel(symbol)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 6) {
                    TextField("Other symbol", text: $other, prompt: Text("Another SF Symbol, such as leaf"))
                        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                        .font(.system(.callout, design: .monospaced)).frame(width: 260)
                        .onSubmit(useOther)
                    Button("Use", action: useOther).disabled(!AutomationSymbols.exists(otherName))
                }
                if !otherName.isEmpty, !AutomationSymbols.exists(otherName) {
                    Text("“\(otherName)” is not an SF Symbol on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        LabeledContent("Colour") {
            HStack(spacing: 8) {
                ForEach(AutomationAccent.allCases, id: \.self) { accent in
                    let selected = draft.accent == accent
                    Button { draft.accent = accent } label: {
                        Circle().fill(AutomationTint.color(accent).gradient)
                            .frame(width: 20, height: 20)
                            .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) } }
                            .padding(3)
                            .overlay(Circle().strokeBorder(selected ? AutomationTint.color(accent) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(accent.title)
                    .accessibilityLabel(accent.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        LabeledContent("In the notch") {
            NotchLookPreview(symbol: draft.symbol, accent: draft.accent)
        }
    }

    /// The offered symbols, with a saved one that is not among them first, so it stays visible and selected.
    private var symbols: [String] {
        AutomationSymbols.all.contains(draft.symbol) ? AutomationSymbols.all : [draft.symbol] + AutomationSymbols.all
    }

    private var otherName: String { other.trimmingCharacters(in: .whitespaces).lowercased() }

    private func useOther() {
        guard AutomationSymbols.exists(otherName) else { return }
        draft.symbol = otherName
        other = ""
    }
}

/// A still picture of the running pill: the icon at the left, one ring at the right, as the notch draws them.
struct NotchLookPreview: View {
    let symbol: String
    let accent: AutomationAccent

    var body: some View {
        HStack(spacing: 8) {
            NotchGlyph(symbol: symbol, accent: accent.rawValue, phase: .running, diameter: 20)
            Spacer(minLength: 40)
            NotchProgressRing(progress: 0.62, tint: NotchStyle.ring, size: 14, reduceMotion: true)
        }
        .padding(.horizontal, 10)
        .frame(width: 150, height: 30)
        .background(Capsule().fill(Color.black))
        .environment(\.colorScheme, .dark)
        .accessibilityElement()
        .accessibilityLabel("Preview of the notch icon")
    }
}

struct EditorAgent: View {
    @Binding var draft: AutomationDraft
    var body: some View {
        let diagnosis = draft.kind == .scriptWithDiagnosis
        Section(diagnosis ? "Diagnosis when the script fails" : "Agent") {
            AgentProviderFields(runner: $draft.runner, model: $draft.model, effort: $draft.effort, fast: $draft.fast)
            VStack(alignment: .leading, spacing: 6) {
                Text(diagnosis ? "Diagnosis prompt (optional)" : "Prompt")
                TextEditor(text: $draft.prompt)
                    .accessibilityLabel(diagnosis ? "Diagnosis prompt" : "Prompt")
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
        case .proposal: return draft.access.canWrite
            ? "The proposal needs your approval. This access also lets the agent change files directly while it runs."
            : "Suggests file changes. Nothing changes until you approve each one."
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
                    .accessibilityLabel("Arguments, one per line")
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
            TextField("Shared lock", text: $draft.sharedLock, prompt: Text("Optional, such as data-refresh"))
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

/// Secret names live in the automation; values go straight to the Keychain and are never shown again.
struct SecretNamesField: View {
    @Binding var names: [String]
    @State private var newName = ""
    @State private var values: [String: String] = [:]
    @State private var stored: Set<String> = []
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secrets")
            ForEach(names, id: \.self) { name in
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text(name).font(.system(.callout, design: .monospaced))
                    Spacer()
                    SecureField(stored.contains(name) ? "Saved; type to replace" : "Value", text: Binding(
                        get: { values[name, default: ""] }, set: { values[name] = $0 }))
                        .frame(width: 180).onSubmit { saveValue(name) }
                    Button("Save") { saveValue(name) }.disabled(values[name, default: ""].isEmpty)
                    Button { names.removeAll { $0 == name } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Remove \(name)")
                }
            }
            HStack(spacing: 6) {
                TextField("NAME", text: $newName).font(.system(.callout, design: .monospaced)).onSubmit(add)
                Button("Add", action: add).disabled(!AutomationDraft.isEnvName(newName) || names.contains(newName))
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            Text("Passed to this script only, as environment values. Values are kept in the Keychain, never in the automation file.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { stored = Set(names.filter { AutomationSecrets.exists(name: $0) }) }
    }
    private func saveValue(_ name: String) {
        guard let value = values[name], !value.isEmpty else { return }
        do { try AutomationSecrets.save(name: name, value: value); stored.insert(name); values[name] = ""; problem = nil }
        catch { problem = "Could not save \(name) in the Keychain." }
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
