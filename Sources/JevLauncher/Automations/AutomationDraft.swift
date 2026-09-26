import Foundation
import LauncherCore

/// Everything the editor shows, as plain values. Builds an `Automation` and says why it cannot yet.
/// Pure: file checks come in through `isExecutable`, so views never touch the disk while drawing.
struct AutomationDraft: Equatable {
    enum KindChoice: String, CaseIterable, Identifiable {
        case agent, script, scriptWithDiagnosis
        var id: String { rawValue }
        var title: String {
            switch self { case .agent: return "Agent"; case .script: return "Script"; case .scriptWithDiagnosis: return "Script + diagnosis" }
        }
    }

    struct EnvPair: Equatable, Identifiable {
        var id = UUID()
        var key: String
        var value: String
    }

    static let defaultDiagnosisPrompt = "The script failed. Read its output and error, find the likely cause, and write a short report with the next step to fix it. Do not change any files."

    /// Nil for a new automation.
    var existing: Automation?
    var name = ""
    var symbol = "gearshape.2"
    var kind: KindChoice = .agent
    var notes = ""

    // Agent
    var runner: AgentRunner = .codex
    var model = ""
    var effort: ReasoningEffort = .medium
    var fast = false
    var prompt = ""
    var output: OutputMode = .report
    var access: AgentAccess = .readOnly
    var agentFolder = ""
    var allowedRoots: [String] = []

    // Script
    var program = ""
    var argumentsText = ""
    var scriptFolder = ""
    var environment: [EnvPair] = []
    var secretNames: [String] = []
    var sharedLock = ""

    var schedule = ScheduleDraft()
    var policy = Policy()
    /// New automations are saved paused, then turned on when this is set.
    var enableAfterSaving = true

    init() {}

    init(_ automation: Automation) {
        existing = automation
        name = automation.name; symbol = automation.symbol; notes = automation.notes
        schedule = ScheduleDraft(automation.schedule); policy = automation.policy
        sharedLock = automation.policy.sharedLock ?? ""
        enableAfterSaving = automation.enabled
        switch automation.kind {
        case .agent(let agent): kind = .agent; fill(agent)
        case .script(let script): kind = .script; fill(script)
        case .scriptWithDiagnosis(let script, let agent): kind = .scriptWithDiagnosis; fill(script); fill(agent)
        }
    }

    private mutating func fill(_ agent: AgentTask) {
        runner = agent.runner; model = agent.model; effort = agent.effort; fast = agent.fast
        prompt = agent.prompt; output = agent.output; access = agent.access
        agentFolder = Paths.display(agent.workingDirectory); allowedRoots = agent.allowedRoots.map(Paths.display)
    }

    private mutating func fill(_ script: ScriptTask) {
        program = script.executable; argumentsText = script.arguments.joined(separator: "\n")
        scriptFolder = Paths.display(script.workingDirectory)
        environment = script.environment.sorted { $0.key < $1.key }.map { EnvPair(key: $0.key, value: $0.value) }
        secretNames = script.secretNames
    }

    @MainActor mutating func applyDefaults(_ preferences: Preferences) {
        let agent = preferences.defaultAgentTask(prompt: prompt, workingDirectory: agentFolder)
        runner = agent.runner; model = agent.model; effort = agent.effort; fast = agent.fast
        // Proposal templates must not gain direct write access from a default.
        if output != .proposal { access = agent.access }
        policy.timeout = preferences.defaultAutomationPolicy.timeout
        policy.alertOnFailure = preferences.defaultAutomationPolicy.alertOnFailure
    }

    var isNew: Bool { existing == nil }
    var usesAgent: Bool { kind != .script }
    var usesScript: Bool { kind != .agent }

    /// Preserve saved argv exactly when this field was not edited.
    var arguments: [String] {
        if let existing {
            let saved: [String]
            switch existing.kind {
            case .script(let script), .scriptWithDiagnosis(let script, _): saved = script.arguments
            case .agent: saved = []
            }
            if argumentsText == saved.joined(separator: "\n") { return saved }
        }
        return argumentsText.split(whereSeparator: \.isNewline).map(String.init)
    }

    var commandLinePreview: String {
        program.isEmpty ? "" : ScriptTask(executable: program, arguments: arguments, workingDirectory: "").commandLine
    }

    // MARK: Validation

    /// Every reason Save is off, in the order the form shows them. Empty means it can save.
    func problems(isExecutable: (String) -> Bool, now: Date = Date()) -> [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Add a name.") }
        if usesAgent {
            if kind == .agent, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append("Write a prompt.") }
            if kind == .agent, agentFolder.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Choose a working folder.") }
            else if kind == .agent, !Paths.isAbsolute(agentFolder) { found.append("The working folder must be a full path.") }
            if kind == .agent, output == .proposal, allowedRoots.isEmpty { found.append("“Changes to approve” needs at least one allowed folder.") }
            if allowedRoots.contains(where: { !Paths.isAbsolute($0) }) { found.append("Allowed folders must be full paths.") }
        }
        if usesScript {
            let path = program.trimmingCharacters(in: .whitespaces)
            if path.isEmpty { found.append("Choose the program to run.") }
            else if !path.hasPrefix("/") { found.append("The program needs a full path, such as /opt/homebrew/bin/bun.") }
            else if !isExecutable(path) { found.append("The program is not an executable file.") }
            if scriptFolder.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Choose a working folder for the script.") }
            else if !Paths.isAbsolute(scriptFolder) { found.append("The script's working folder must be a full path.") }
            if environment.contains(where: { !Self.isEnvName($0.key) }) { found.append("Environment names use letters, digits, and _ only.") }
            if secretNames.contains(where: { !Self.isEnvName($0) }) { found.append("Secret names use letters, digits, and _ only.") }
        }
        if case .failure(let problem) = schedule.rule(now: now) { found.append("Schedule: " + problem.message) }
        if policy.timeout < 10 { found.append("The time limit must be at least 10 seconds.") }
        if !sharedLock.isEmpty, !AutomationID.isValid(sharedLock) { found.append("Lock names use a-z, 0-9, and -.") }
        return found
    }

    static func isEnvName(_ name: String) -> Bool {
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    // MARK: Building

    /// The automation to save, or nil while there are problems. New automations are always paused here.
    func build(isExecutable: (String) -> Bool, now: Date = Date()) -> Automation? {
        guard problems(isExecutable: isExecutable, now: now).isEmpty, let schedule = schedule.schedule(now: now) else { return nil }
        var policy = self.policy
        policy.sharedLock = sharedLock.isEmpty ? nil : sharedLock
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var automation = existing ?? Automation(id: AutomationID.make(from: trimmedName), name: trimmedName, kind: .agent(agentTask),
                                                schedule: schedule, created: now)
        automation.name = trimmedName
        automation.symbol = symbol
        automation.schedule = schedule
        automation.policy = policy
        automation.notes = notes
        switch kind {
        case .agent: automation.kind = .agent(agentTask)
        case .script: automation.kind = .script(scriptTask)
        case .scriptWithDiagnosis: automation.kind = .scriptWithDiagnosis(scriptTask, diagnosisTask)
        }
        if existing == nil { automation.enabled = false }
        return automation
    }

    var agentTask: AgentTask {
        AgentTask(runner: runner, prompt: prompt, model: model.trimmingCharacters(in: .whitespaces), effort: effort,
                  fast: runner == .codex && fast, workingDirectory: Paths.expand(agentFolder),
                  allowedRoots: allowedRoots.map(Paths.expand), access: access, output: output)
    }

    /// A diagnosis only reads and reports. It works in the script's folder.
    private var diagnosisTask: AgentTask {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentTask(runner: runner, prompt: text.isEmpty ? Self.defaultDiagnosisPrompt : text, model: model.trimmingCharacters(in: .whitespaces),
                         effort: effort, fast: runner == .codex && fast, workingDirectory: Paths.expand(scriptFolder),
                         allowedRoots: [], access: .readOnly, output: .report)
    }

    var scriptTask: ScriptTask {
        var env: [String: String] = [:]
        for pair in environment where !pair.key.isEmpty { env[pair.key] = pair.value }
        return ScriptTask(executable: program.trimmingCharacters(in: .whitespaces), arguments: arguments,
                          workingDirectory: Paths.expand(scriptFolder), environment: env, secretNames: secretNames)
    }
}

/// Home-relative paths for display and entry.
enum Paths {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + trimmed.dropFirst(1) }
        return trimmed
    }
    static func display(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
    static func isAbsolute(_ path: String) -> Bool {
        let t = path.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("/") || t == "~" || t.hasPrefix("~/")
    }
}
