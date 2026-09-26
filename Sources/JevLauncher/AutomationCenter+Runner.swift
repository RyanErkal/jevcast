import AppKit
import LauncherCore
import Security
import ServiceManagement

/// The background runner's launch agent, through SMAppService. Calls here may wait on launchd, so callers run them off the main thread.
enum RunnerService {
    static let plistName = "com.ryanerkal.jevlauncher.runner.plist"

    enum Status: Sendable { case notRegistered, enabled, requiresApproval, notFound }

    static func status() -> Status {
        switch SMAppService.agent(plistName: plistName).status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// Returns an error message, or nil.
    static func register() -> String? {
        do { try SMAppService.agent(plistName: plistName).register(); return nil } catch { return error.localizedDescription }
    }

    static func unregister() -> String? {
        do { try SMAppService.agent(plistName: plistName).unregister(); return nil } catch { return error.localizedDescription }
    }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// True when the app carries a real signature: not ad hoc and with a team identifier. macOS does not register agents of ad-hoc apps.
    static func isSignedBuild(_ url: URL = Bundle.main.bundleURL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        return !adhoc && !(team ?? "").isEmpty
    }
}

extension AutomationCenter {
    /// Maps the agent status and the heartbeat to one status. See `RunnerStatus`.
    func updateRunnerStatus() {
        guard !isolated else { runnerStatus = .off; return }
        let known = signedBuild
        Task { @MainActor [weak self] in
            let (signed, status) = await Task.detached(priority: .utility) { () -> (Bool, RunnerService.Status) in
                (known ?? RunnerService.isSignedBuild(), RunnerService.status())
            }.value
            guard let self else { return }
            self.signedBuild = signed
            let next = Self.runnerStatus(signed: signed, service: status, heartbeat: self.heartbeat,
                                         enabledSince: self.enabledSince, now: Date())
            if status == .enabled, self.enabledSince == nil { self.enabledSince = Date() }
            if status != .enabled { self.enabledSince = nil }
            if self.runnerStatus != next {
                self.runnerStatus = next
                self.scheduleRescan()
            }
        }
    }

    nonisolated static func runnerStatus(signed: Bool, service: RunnerService.Status, heartbeat: RunnerHeartbeat?,
                                         enabledSince: Date?, now: Date) -> RunnerStatus {
        guard signed else { return .unsignedBuild }
        switch service {
        case .notRegistered: return .off
        case .requiresApproval: return .needsApproval
        case .notFound: return .failed("Runner missing from app bundle")
        case .enabled:
            if let heartbeat, heartbeat.isFresh(now: now) { return .running(since: heartbeat.started) }
            // Just registered, or first seen this session: give it 90 seconds to beat.
            if now.timeIntervalSince(enabledSince ?? now) < 90 { return .starting }
            return .notResponding
        }
    }

    func registerRunner() {
        guard !isolated else { return }
        if signedBuild == false { message = "This copy of Jevcast is signed ad hoc, so macOS will not run its background runner."; return }
        Task { @MainActor [weak self] in
            let error = await Task.detached { RunnerService.register() }.value
            guard let self else { return }
            if let error { self.message = "Could not turn on the runner: \(error)" } else {
                self.message = nil
                self.enabledSince = Date()
            }
            self.updateRunnerStatus()
        }
    }

    func unregisterRunner() {
        guard !isolated else { return }
        Task { @MainActor [weak self] in
            let error = await Task.detached { RunnerService.unregister() }.value
            guard let self else { return }
            self.message = error.map { "Could not turn off the runner: \($0)" }
            self.enabledSince = nil
            self.updateRunnerStatus()
        }
    }

    // MARK: Tools

    /// Looks for `codex` and `claude` in known places and records their paths in the settings.
    func detectTools() {
        guard !isolated, !detectingTools else { return }
        detectingTools = true
        let saved = (codex: settings.codexPath, claude: settings.claudePath)
        Task { @MainActor [weak self] in
            async let codex = Task.detached(priority: .utility) { ToolProbe.find("codex", saved: saved.codex) }.value
            async let claude = Task.detached(priority: .utility) { ToolProbe.find("claude", saved: saved.claude) }.value
            let found = await (codex, claude)
            guard let self else { return }
            self.detectingTools = false
            self.codexTool = found.0.map { ToolInfo(path: $0.path, version: $0.version) }
            self.claudeTool = found.1.map { ToolInfo(path: $0.path, version: $0.version) }
            var s = self.settings
            s.codexPath = found.0?.path ?? ""
            s.claudePath = found.1?.path ?? ""
            s.claudeUsesSettingsSignIn = ClaudeSignIn.gatewayEnvironment() != nil
            s.scriptPath = Self.scriptPath(s.scriptPath, adding: [found.0?.path, found.1?.path].compactMap { $0 })
            if s != self.settings { self.saveSettings(s) }
        }
    }

    /// Adds the folders of found tools, and Bun's usual folder, to the script PATH, so scripts such as
    /// `bun … ` that start `node` or `wrangler` work under launchd. Existing entries keep their order.
    nonisolated static func scriptPath(_ current: String, adding tools: [String], home: String = NSHomeDirectory()) -> String {
        var parts = current.split(separator: ":").map(String.init)
        let extra = tools.map { ($0 as NSString).deletingLastPathComponent } + [home + "/.bun/bin", home + "/.local/bin"]
        for dir in extra where !parts.contains(dir) && FileManager.default.fileExists(atPath: dir) { parts.insert(dir, at: 0) }
        return parts.joined(separator: ":")
    }

    /// Uses a CLI the user chose in an open panel.
    func chooseTool(_ runner: AgentRunner, path: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else { message = "That file cannot run."; return }
        var s = settings
        if runner == .codex { s.codexPath = path } else { s.claudePath = path }
        saveSettings(s)
        detectTools()
    }
}

/// Finds a CLI and reads its version, off the main thread. Never runs a login shell.
enum ToolProbe {
    struct Found: Sendable { var path: String; var version: String? }

    static func find(_ name: String, saved: String) -> Found? {
        let home = NSHomeDirectory()
        let nvm = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.nvm/versions/node")) ?? []
        for path in ToolLocator.candidates(name: name, saved: saved, home: home, nvmVersions: nvm)
        where FileManager.default.isExecutableFile(atPath: path) {
            return Found(path: path, version: version(path))
        }
        return nil
    }

    /// `<tool> --version` with a 5-second limit and a fixed small environment.
    static func version(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let dir = (path as NSString).deletingLastPathComponent
        // Node-based CLIs find `node` beside them or in Homebrew.
        process.environment = ["PATH": "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        let data = (try? out.fileHandleForReading.read(upToCount: 4096)) ?? nil
        return data.flatMap { ToolLocator.versionLine(String(decoding: $0, as: UTF8.self)) }
    }
}
