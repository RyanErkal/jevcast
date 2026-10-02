import Foundation

/// Only known workers without a parent can be stopped. Low CPU alone never proves a thread is idle.
public enum ComputerUseCleanup {
    public enum Kind: String, Sendable {
        case repl = "Computer Use Worker"
        case history = "Computer History Worker"
        case service = "Computer Use Service"
    }

    private static let runtimes = ["/Applications/ChatGPT.app/Contents/Resources/cua_node",
                                   "/Applications/Codex.app/Contents/Resources/cua_node"]

    public static func kind(_ process: CleanupProcess, home: String) -> Kind? {
        guard let identity = process.identity, identity.path == process.path else { return nil }
        for runtime in runtimes where identity.path == runtime + "/bin/node" {
            if identity.arguments == [identity.path, runtime + "/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs"] { return .repl }
        }
        let bundle = home + "/.codex/computer-use/Codex Computer Use.app/Contents"
        if identity.path == bundle + "/MacOS/SkyComputerUseService" { return .service }
        if identity.path == bundle + "/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient",
           identity.arguments == [identity.path, "computer-history", "mcp"] { return .history }
        return nil
    }

    /// Protect coding sessions even when their host app is not visible or a runner is detached.
    public static func isAgentHost(_ process: CleanupProcess) -> Bool {
        process.name.hasPrefix("codex") || process.name.hasPrefix("claude")
            || ["jevcast-runner", "agent-device", "node_repl"].contains(process.name)
            || process.path.contains("/cua_node/")
            || process.path.contains("/Codex Computer Use.app/")
            || process.path.contains("/T3 Code")
            || process.path.contains("/ChatGPT.app/")
            || process.path.contains("/Codex.app/")
            || (process.identity?.arguments?.contains { argument in
                argument.hasSuffix("/bin/codex") || argument.hasSuffix("/bin/claude")
                    || argument.contains("/node_modules/@anthropic-ai/claude-code/")
                    || argument.contains("/node_modules/@openai/codex/")
                    || argument.contains("/node_modules/agent-device/")
                    || argument == "--ipc-path" || argument == "--session-id"
                    || argument.hasSuffix("/trusted-worker.js")
            } == true)
    }

    private static func idleChild(_ process: CleanupProcess) -> Bool {
        guard let identity = process.identity else { return false }
        return runtimes.contains { identity.path == $0 + "/bin/node_repl" }
            && identity.arguments == [identity.path]
    }

    public static func find(_ input: CleanupRules.Input) -> [CleanupFinding] {
        let parents = Dictionary(input.processes.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        let hosts = input.protectedRoots.union(input.processes.filter(isAgentHost).map(\.pid))
        return input.processes.compactMap { root in
            guard root.uid == input.uid, let kind = kind(root, home: input.homeDirectory) else { return nil }
            let family = input.processes.filter { CleanupRules.descends($0.pid, from: [root.pid], parents: parents) }
            let children = family.filter { $0.pid != root.pid }
            let owner = input.processes.first { $0.pid == root.ppid }
            let safe = kind != .service && root.ppid == 1 && root.elapsed >= 60
                && family.allSatisfy { process in
                    process.identity != nil && process.uid == input.uid && process.cpu < 1
                        && !input.launchdPIDs.contains(process.pid) && !input.listening.keys.contains(process.pid)
                        && !CleanupRules.descends(process.pid, from: input.protectedRoots, parents: parents)
                }
                && children.allSatisfy(idleChild)
                && !children.contains { CleanupRules.descends($0.pid, from: hosts.subtracting(family.map(\.pid)), parents: parents) }
            let reason: String
            if kind == .service { reason = "Shared service; left running" }
            else if root.ppid != 1 {
                reason = owner.map { "Attached to \($0.name) (PID \($0.pid)); left running" }
                    ?? "Parent cannot be verified; left running"
            } else if safe { reason = "No parent app; review before stopping" }
            else { reason = "Activity or ownership cannot be ruled out; left running" }
            let key = "computer-use:\(root.pid)"
            guard !input.ignoredKeys.contains(key) else { return nil }
            let names = ([kind == .repl ? "cua-repl.mjs" : root.name] + children.map(\.name)).joined(separator: ", ")
            return CleanupFinding(group: .computerUse, key: key, title: kind.rawValue + " (PID \(root.pid))",
                                  detail: reason + " · " + names, pids: [root.pid] + children.map(\.pid),
                                  memoryMB: family.map(\.memoryMB).reduce(0, +), checked: false, canStop: safe)
        }
    }
}
