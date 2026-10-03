import Foundation

/// Creates or updates automations from a reviewed definition file (`jevcast-runner --configure <file>`).
/// It never turns an automation on: new ones start paused and existing ones keep their on/off state.
/// Every save records the programs and script files as approved, like a save in the editor.
public enum AutomationSetup {
    public static let schema = "jevcast.setup.v1"

    public struct Spec: Decodable, Sendable {
        public var schema: String
        /// Lowers the number of runs at a time to this value. Never raises it.
        public var maxConcurrentRuns: Int?
        public var automations: [Entry]
    }

    public struct Entry: Decodable, Sendable {
        public var id: String
        public var name: String
        public var symbol: String?
        public var notes: String?
        public var schedule: ScheduleSpec
        public var policy: Policy
        public var script: ScriptTask?
        public var diagnosis: AgentTask?
        public var agent: AgentTask?
        public var staged: StagedTask?
        public var pinnedFiles: [String]?
    }

    public struct ScheduleSpec: Decodable, Sendable {
        /// Without the "RRULE:" prefix, for example "FREQ=HOURLY;BYMINUTE=0".
        public var rrule: String
        public var timeZone: String
    }

    public struct Change: Equatable, Sendable, Encodable {
        public enum Kind: String, Encodable, Sendable { case created, updated, reapproved, unchanged }
        public var id: String
        public var kind: Kind
        public var enabled: Bool
        public var revision: Int
        public var schedule: String
        public var nextRun: Date?
    }

    public struct Report: Encodable, Sendable {
        public var applied: Bool
        public var problems: [String]
        public var changes: [Change]
        public var maxConcurrentRuns: Int
    }

    public static func decode(_ data: Data) throws -> Spec {
        try JSONDecoder().decode(Spec.self, from: data)
    }

    /// Every reason the spec cannot be applied. Empty means it can.
    public static func problems(_ spec: Spec, settings: AutomationSettings, fileExists: (String) -> Bool = FileManager.default.isExecutableFile) -> [String] {
        var found: [String] = []
        if spec.schema != schema { found.append("schema must be \(schema)") }
        if let cap = spec.maxConcurrentRuns, !(1...4).contains(cap) { found.append("maxConcurrentRuns must be 1 to 4") }
        var ids = Set<String>()
        for e in spec.automations {
            let at = "\(e.id): "
            if !AutomationID.isValid(e.id) { found.append(at + "the ID must use a-z, 0-9, and -") }
            if !ids.insert(e.id).inserted { found.append(at + "the ID is used twice") }
            if e.name.trimmingCharacters(in: .whitespaces).isEmpty { found.append(at + "the name is empty") }
            if (try? RRule(e.schedule.rrule)) == nil { found.append(at + "the schedule rule is not valid") }
            if TimeZone(identifier: e.schedule.timeZone) == nil { found.append(at + "unknown time zone \(e.schedule.timeZone)") }
            if e.policy.timeout < 10 { found.append(at + "the time limit must be at least 10 seconds") }
            if let lock = e.policy.sharedLock, !AutomationID.isValid(lock) { found.append(at + "the lock name must use a-z, 0-9, and -") }
            let kinds = [e.script != nil && e.agent == nil && e.staged == nil, e.agent != nil && e.script == nil && e.staged == nil,
                         e.staged != nil && e.script == nil && e.agent == nil && e.diagnosis == nil]
            if kinds.filter({ $0 }).count != 1 { found.append(at + "give exactly one of script, agent, or staged") }
            var scripts: [ScriptTask] = []
            var agents: [AgentTask] = []
            if let s = e.script { scripts.append(s) }
            if let d = e.diagnosis { agents.append(d); if d.access != .readOnly || d.output != .report { found.append(at + "a diagnosis is read only and writes a report") } }
            if let a = e.agent { agents.append(a) }
            if let t = e.staged {
                if let problem = t.problem() { found.append(at + problem) }
                scripts += t.scripts
                agents.append(t.analyst)
                if t.analyst.access != .readOnly { found.append(at + "the analyst must be read only") }
                if let f = t.fetch {
                    agents.append(f.agent)
                    if f.agent.access != .readOnly { found.append(at + "the fetch worker must be read only; its tool does the fetch") }
                    if let program = f.command.first, !fileExists(program) { found.append(at + "the fetch program \(program) is missing") }
                }
            }
            for s in scripts {
                if !s.executable.hasPrefix("/") || !fileExists(s.executable) { found.append(at + "the program \(s.executable) is missing or not a full path") }
                if !s.workingDirectory.hasPrefix("/") { found.append(at + "working folders need full paths") }
                if s.environment.keys.contains(where: RunnerCommand.isBlocked) { found.append(at + "an environment name is not allowed (API keys and base URLs never pass)") }
                let words = ([s.executable] + s.arguments).joined(separator: " ")
                if RunnerCommand.forbiddenArguments.contains(where: words.contains) { found.append(at + "a forbidden argument is used") }
            }
            for a in agents {
                if a.model.trimmingCharacters(in: .whitespaces).isEmpty { found.append(at + "each agent needs an exact model; there is no default or fallback") }
                if !a.workingDirectory.hasPrefix("/") { found.append(at + "agent working folders need full paths") }
                if a.runner == .codex, settings.codexPath.isEmpty { found.append(at + "the Codex CLI was not found; detect it in Settings first") }
                if a.runner == .claude, settings.claudePath.isEmpty { found.append(at + "the Claude CLI was not found; detect it in Settings first") }
            }
            for path in e.pinnedFiles ?? [] where !path.hasPrefix("/") { found.append(at + "pinned files need full paths") }
        }
        return found
    }

    /// The automation an entry describes, keeping an existing one's identity, history, and on/off state.
    public static func automation(_ e: Entry, existing: Automation?, settings: AutomationSettings, now: Date) -> Automation {
        let kind: Automation.Kind
        if let t = e.staged { kind = .staged(t) }
        else if let s = e.script { kind = e.diagnosis.map { .scriptWithDiagnosis(s, $0) } ?? .script(s) }
        else { kind = .agent(e.agent!) }
        let zone = TimeZone(identifier: e.schedule.timeZone) ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let anchor = existing?.schedule.anchor ?? calendar.startOfDay(for: now)
        var a = existing ?? Automation(id: e.id, name: e.name, kind: kind, schedule: Schedule(rule: .manual), created: now)
        a.name = e.name
        a.symbol = e.symbol ?? a.symbol
        a.notes = e.notes ?? ""
        a.kind = kind
        a.schedule = Schedule(rule: .rrule(e.schedule.rrule), timeZone: zone.identifier, anchor: anchor)
        a.policy = e.policy
        a.pinnedFiles = e.pinnedFiles
        a.enabled = existing?.enabled ?? false
        a.recordApprovedPrograms(settings: settings)
        return a
    }

    /// Applies the spec to `store`, or with `check` only reports what would change.
    public static func apply(_ spec: Spec, store: AutomationStore, check: Bool, now: Date = Date()) -> Report {
        var settings = store.loadSettings()
        let found = problems(spec, settings: settings)
        let cap = spec.maxConcurrentRuns.map { min($0, settings.maxConcurrentRuns) } ?? settings.maxConcurrentRuns
        guard found.isEmpty else { return Report(applied: false, problems: found, changes: [], maxConcurrentRuns: settings.maxConcurrentRuns) }
        var changes: [Change] = []
        var problems: [String] = []
        for e in spec.automations {
            let existing = store.automation(id: e.id)
            var next = automation(e, existing: existing, settings: settings, now: now)
            let kind: Change.Kind
            if let existing {
                var a = existing, b = next
                for x in [\Automation.revision, \Automation.updated, \Automation.approvedProgram, \Automation.approvedAgentCLI,
                          \Automation.approvedFiles] as [PartialKeyPath<Automation>] { _ = x }
                a.revision = 0; b.revision = 0; a.updated = now; b.updated = now
                let sameDefinition = { () -> Bool in
                    var x = a, y = b
                    x.approvedProgram = nil; y.approvedProgram = nil; x.approvedAgentCLI = nil; y.approvedAgentCLI = nil
                    x.approvedFiles = nil; y.approvedFiles = nil
                    return x == y
                }()
                if sameDefinition && a == b { kind = .unchanged }
                else { kind = sameDefinition ? .reapproved : .updated }
                next.revision = kind == .unchanged ? existing.revision : existing.revision + 1
                next.updated = kind == .unchanged ? existing.updated : now
            } else {
                kind = .created
                next.revision = 1; next.updated = now
            }
            if !check, kind != .unchanged {
                do { try store.save(next) } catch { problems.append("\(e.id): could not save: \(error)"); continue }
            }
            changes.append(Change(id: e.id, kind: kind, enabled: next.enabled, revision: next.revision, schedule: e.schedule.rrule + " " + e.schedule.timeZone,
                                  nextRun: Scheduler.nextRun({ var x = next; x.enabled = true; return x }(), lastCovered: nil, now: now)))
        }
        if !check, cap != settings.maxConcurrentRuns {
            settings.maxConcurrentRuns = cap
            do { try store.saveSettings(settings) } catch { problems.append("Could not save settings: \(error)") }
        }
        if !check { AutomationSignal.post() }
        return Report(applied: !check && problems.isEmpty, problems: problems, changes: changes, maxConcurrentRuns: cap)
    }
}
