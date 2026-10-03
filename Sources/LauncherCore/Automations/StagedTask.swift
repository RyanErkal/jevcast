import Foundation

/// A report workflow with fixed stages. Approved scripts plan, finish, and record. Agents only read and
/// return text: at most one fetch worker and one analyst per item, one after the other.
///
/// Order in one run: claim → publish proofs from earlier runs → preflight → for each item:
/// [fetch] → analyst → finish. The engine passes only fixed flags to the scripts, and a model never
/// chooses a program or an argument.
public struct StagedTask: Codable, Equatable, Sendable {
    /// Prints one `StagedHandoff` JSON object on stdout. Runs first, every time.
    public var preflight: ScriptTask
    /// Runs once for each item an agent worked on. Writes and checks the artifacts.
    public var finish: ScriptTask
    /// Records that a report was shown. Nil when the workflow keeps no posting receipts.
    public var publish: ScriptTask?
    /// The fetch worker, for items the planner marks as needing new data. Nil when there is none.
    public var fetch: FetchStage?
    /// Always runs read only, with no network, whatever its saved access says.
    public var analyst: AgentTask
    /// Held for the whole run, so two runs never work on the same client at once. `[a-z0-9-]`.
    public var claim: String
    public var limits: StageLimits

    public init(preflight: ScriptTask, finish: ScriptTask, publish: ScriptTask? = nil, fetch: FetchStage? = nil,
                analyst: AgentTask, claim: String, limits: StageLimits = StageLimits()) {
        self.preflight = preflight; self.finish = finish; self.publish = publish; self.fetch = fetch
        self.analyst = analyst; self.claim = claim; self.limits = limits
    }

    /// The scripts, in the order they run.
    public var scripts: [ScriptTask] { [preflight, finish] + (publish.map { [$0] } ?? []) }

    enum CodingKeys: String, CodingKey { case preflight, finish, publish, fetch, analyst, claim, limits }
    /// `limits` may be left out; it then keeps its defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preflight = try c.decode(ScriptTask.self, forKey: .preflight)
        finish = try c.decode(ScriptTask.self, forKey: .finish)
        publish = try c.decodeIfPresent(ScriptTask.self, forKey: .publish)
        fetch = try c.decodeIfPresent(FetchStage.self, forKey: .fetch)
        analyst = try c.decode(AgentTask.self, forKey: .analyst)
        claim = try c.decode(String.self, forKey: .claim)
        limits = try c.decodeIfPresent(StageLimits.self, forKey: .limits) ?? StageLimits()
    }
}

/// One fetch worker per item. It runs one approved command for the item's period and nothing else.
public struct FetchStage: Codable, Equatable, Sendable {
    public static let periodPlaceholder = "{period_key}"
    /// Codex only: the worker needs a command tool. Its working folder is replaced by a fresh staging folder.
    public var agent: AgentTask
    /// Where the command runs, for example the docs repository. The worker can read it but not write it.
    public var commandDirectory: String
    /// The program and arguments. Exactly one argument is `{period_key}`.
    public var command: [String]
    /// The one folder the worker may write, besides its staging folder.
    public var outputDirectory: String

    public init(agent: AgentTask, commandDirectory: String, command: [String], outputDirectory: String) {
        self.agent = agent; self.commandDirectory = commandDirectory; self.command = command; self.outputDirectory = outputDirectory
    }

    /// The exact shell line the worker must run for `periodKey`. Every word is quoted when needed.
    public func commandLine(periodKey: String) -> String {
        let words = command.map { $0 == Self.periodPlaceholder ? periodKey : $0 }
        return "cd " + ShellWord.quote(commandDirectory) + " && " + words.map(ShellWord.quote).joined(separator: " ")
    }
}

/// Seconds per stage, and the most items one run handles.
public struct StageLimits: Codable, Equatable, Sendable {
    public var preflight: Int
    public var fetch: Int
    public var analyst: Int
    public var finish: Int
    public var publish: Int
    /// 1...3.
    public var maxItems: Int

    public init(preflight: Int = 1200, fetch: Int = 1200, analyst: Int = 1500, finish: Int = 600, publish: Int = 120, maxItems: Int = 3) {
        self.preflight = preflight; self.fetch = fetch; self.analyst = analyst; self.finish = finish
        self.publish = publish; self.maxItems = maxItems
    }

    enum CodingKeys: String, CodingKey { case preflight, fetch, analyst, finish, publish, maxItems }
    /// Missing keys keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StageLimits()
        preflight = try c.decodeIfPresent(Int.self, forKey: .preflight) ?? d.preflight
        fetch = try c.decodeIfPresent(Int.self, forKey: .fetch) ?? d.fetch
        analyst = try c.decodeIfPresent(Int.self, forKey: .analyst) ?? d.analyst
        finish = try c.decodeIfPresent(Int.self, forKey: .finish) ?? d.finish
        publish = try c.decodeIfPresent(Int.self, forKey: .publish) ?? d.publish
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems
    }
}

/// Quoting for the one shell line a fetch worker is told to run. Plain words stay as they are.
public enum ShellWord {
    public static func quote(_ word: String) -> String {
        let plain = !word.isEmpty && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0)) }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension StagedTask {
    /// Why this workflow cannot run as saved, or nil. The checks hold whatever the saved file says.
    public func problem() -> String? {
        guard AutomationID.isValid(claim) else { return "The claim name must use a-z, 0-9, and -." }
        guard (1...3).contains(limits.maxItems) else { return "A report workflow handles 1 to 3 items per run." }
        let times = [limits.preflight, limits.fetch, limits.analyst, limits.finish, limits.publish]
        guard times.allSatisfy({ (10...7200).contains($0) }) else { return "Each stage needs a time limit from 10 seconds to 2 hours." }
        for script in scripts where !script.executable.hasPrefix("/") { return "Each stage program needs a full path." }
        guard analyst.output == .report else { return "The analyst writes a report; it cannot ask or propose changes." }
        if let fetch {
            guard fetch.agent.runner == .codex else { return "The fetch worker needs Codex, which can run its one command." }
            guard fetch.command.filter({ $0 == FetchStage.periodPlaceholder }).count == 1, fetch.command.count >= 2 else {
                return "The fetch command needs exactly one {period_key} argument."
            }
            guard fetch.commandDirectory.hasPrefix("/"), fetch.outputDirectory.hasPrefix("/") else {
                return "The fetch folders need full paths."
            }
            let words = fetch.command.joined(separator: " ")
            if RunnerCommand.forbiddenArguments.contains(where: words.contains) { return "The fetch command uses a forbidden argument." }
        }
        return nil
    }
}
