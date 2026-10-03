import Darwin
import Foundation

/// What one fetch tool may run. Written by the runner into the run folder before the worker starts;
/// the worker cannot change it. Every value comes from the saved `FetchStage` and the planner's checked period.
public struct FetchToolSpec: Codable, Equatable, Sendable {
    public static let schemaID = "jevcast.fetch-tool.v1"
    public static let toolName = "fetch_report_bundle"
    public var schema = FetchToolSpec.schemaID
    public var periodKey: String
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    /// Seconds.
    public var timeout: Int
    /// Written once, with `O_EXCL`, so the command runs at most once per spec.
    public var resultFile: String
    /// The child's group ID and start time while it runs, so the runner can stop exactly it afterwards.
    public var childFile: String

    public init(periodKey: String, executable: String, arguments: [String], workingDirectory: String,
                environment: [String: String], timeout: Int, resultFile: String, childFile: String) {
        self.periodKey = periodKey; self.executable = executable; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.environment = environment; self.timeout = timeout
        self.resultFile = resultFile; self.childFile = childFile
    }
}

/// What the tool's one command did. Written by Jevcast's own code, never by a model.
public struct FetchToolResult: Codable, Equatable, Sendable {
    public var state: String
    public var periodKey: String
    public var argv: [String]
    public var exitCode: Int32?
    /// exited, timedOut, cancelled, signaled, or spawnFailed.
    public var reason: String
    /// The command's stdout tail, which holds its JSON manifest.
    public var stdout: String
    /// Redacted stderr tail.
    public var stderr: String
    public var started: Date
    public var finished: Date?

    public var succeeded: Bool { state == "finished" && reason == "exited" && exitCode == 0 }
}

/// The child group record in `FetchToolSpec.childFile`.
public struct FetchToolChild: Codable, Equatable, Sendable {
    public var pgid: Int32
    public var start: Date?
}

/// `jevcast-runner --fetch-tool <spec>`: a stdio MCP server with exactly one tool and no inputs. The tool
/// runs the spec's fixed command once and returns its stdout. The worker that calls it has no shell, a
/// read-only sandbox, and no network, so this server's one command is its only way to act.
public final class FetchToolServer: @unchecked Sendable {
    public static let serverName = "jevfetch"
    public let spec: FetchToolSpec
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var supervisor: ProcessSupervisor?
    private var stopped = false
    private let calls = DispatchGroup()

    public init(spec: FetchToolSpec) { self.spec = spec }

    /// Reads a spec the runner wrote. Nil when it is missing, too large, not owned, or invalid.
    public static func loadSpec(_ path: String) -> FetchToolSpec? {
        guard let data = try? SecureFile.read(URL(fileURLWithPath: path), maxBytes: 256 * 1024),
              let spec = try? AutomationJSON.decoder().decode(FetchToolSpec.self, from: data),
              spec.schema == FetchToolSpec.schemaID, spec.executable.hasPrefix("/"), spec.resultFile.hasPrefix("/"),
              spec.childFile.hasPrefix("/"), StagedHandoff.isPeriodKey(spec.periodKey), (10...7200).contains(spec.timeout) else { return nil }
        return spec
    }

    /// Stops a running command (TERM, then KILL to its group). For SIGTERM and for the end of input.
    public func stop() {
        lock.lock(); stopped = true; let s = supervisor; lock.unlock()
        s?.cancel()
    }

    /// Serves until `input` ends. Each line is one JSON-RPC message.
    public func serve(input: FileHandle, output: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.count > 1024 * 1024 { break }
            while let nl = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                handle(Data(line), output: output)
            }
        }
        // The client is gone: a command still running is stopped, not left behind.
        stop()
        calls.wait()
    }

    func handle(_ line: Data, output: FileHandle) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let method = message["method"] as? String else { return }
        guard let id = message["id"], !(id is NSNull) else { return } // notifications need no answer
        switch method {
        case "initialize":
            let version = ((message["params"] as? [String: Any])?["protocolVersion"] as? String) ?? "2025-06-18"
            reply(id, result: ["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                               "serverInfo": ["name": Self.serverName, "version": "1"]], output: output)
        case "ping":
            reply(id, result: [String: Any](), output: output)
        case "tools/list":
            reply(id, result: ["tools": [[
                "name": FetchToolSpec.toolName,
                "description": "Runs the approved report-data fetch for period \(spec.periodKey) once and returns its JSON manifest. Takes no input.",
                "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false] as [String: Any],
                // Truthful hints: it writes a report bundle (not read only), adds rather than deletes, and reads remote services.
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true],
            ] as [String: Any]]], output: output)
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard params["name"] as? String == FetchToolSpec.toolName, arguments.isEmpty else {
                reply(id, result: toolText("Unknown tool or unexpected input. This server has one tool and it takes no input.", error: true), output: output)
                return
            }
            calls.enter()
            let box = IDBox(id)
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { calls.leave() }
                let (text, failed) = runOnce()
                reply(box.id, result: toolText(text, error: failed), output: output)
            }
        default:
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"] as [String: Any]], output: output)
        }
    }

    /// Runs the command at most once for this spec. Returns the text for the model and whether it failed.
    func runOnce() -> (String, Bool) {
        let resultURL = URL(fileURLWithPath: spec.resultFile)
        var record = FetchToolResult(state: "running", periodKey: spec.periodKey, argv: [spec.executable] + spec.arguments,
                                     exitCode: nil, reason: "running", stdout: "", stderr: "", started: Date(), finished: nil)
        // The first record is created exclusively: a second call, from any process, finds it and stops.
        guard let first = try? AutomationJSON.encoder().encode(record), Self.createExclusive(resultURL, first) else {
            return ("This fetch already ran for this run. It runs once.", true)
        }
        let supervisor = ProcessSupervisor()
        supervisor.stdoutTailBytes = 256 * 1024
        supervisor.stderrTailBytes = 64 * 1024
        lock.lock(); self.supervisor = supervisor; let cancelled = stopped; lock.unlock()
        if cancelled { supervisor.cancel() }
        let launch = ProcessLaunch(executable: spec.executable, arguments: spec.arguments, environment: spec.environment,
                                   workingDirectory: spec.workingDirectory, stdin: Data())
        let childURL = URL(fileURLWithPath: spec.childFile)
        let identity = Flag()
        let outcome = supervisor.runRecording(launch, timeout: TimeInterval(spec.timeout), onStart: { pid in
            // Without a saved identity the runner could not stop this group later, so it does not run on.
            let child = FetchToolChild(pgid: pid, start: ProcessInfoReader.startTime(pid))
            do { try SecureFile.write(try AutomationJSON.encoder().encode(child), to: childURL); identity.set() }
            catch { identity.fail("\(error)"); supervisor.cancel() }
        }, onLine: { _ in })
        let secrets = Array(spec.environment.values).filter { $0.count >= 8 }
        record.state = "finished"
        record.exitCode = outcome.exitCode
        // Without a saved identity the result never counts, even if the command already exited 0.
        record.reason = identity.value ? Self.reasonName(outcome.reason) : "identityNotSaved"
        record.stdout = Redactor.tail(outcome.stdoutTail, maxBytes: 64 * 1024)
        record.stderr = Redactor.redact(Redactor.tail(outcome.stderrTail, maxBytes: 16 * 1024), known: secrets)
        record.finished = Date()
        // Success is reported only after the finished record is on disk; the runner trusts that record, not this reply.
        do { try SecureFile.write(try AutomationJSON.encoder().encode(record), to: resultURL) } catch {
            return ("The fetch result could not be recorded, so it does not count: \(error)", true)
        }
        if outcome.succeeded, identity.value { return (record.stdout, false) }
        if !identity.error.isEmpty { return ("The fetch was stopped because its process identity could not be saved: \(identity.error).", true) }
        if !identity.value { return ("The fetch was stopped before its command started (\(record.reason)).", true) }
        let last = record.stderr.split(whereSeparator: \.isNewline).suffix(5).joined(separator: "\n")
        return ("The fetch command failed (\(record.reason), exit \(outcome.exitCode.map(String.init) ?? "none")).\n\(last)", true)
    }

    static func reasonName(_ reason: ProcessOutcome.Reason) -> String {
        switch reason {
        case .exited: return "exited"
        case .timedOut: return "timedOut"
        case .cancelled: return "cancelled"
        case .signaled: return "signaled"
        case .spawnFailed: return "spawnFailed"
        case .identityNotSaved: return "identityNotSaved"
        }
    }

    static func createExclusive(_ url: URL, _ data: Data) -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return n == data.count && fsync(fd) == 0
    }

    private func toolText(_ text: String, error: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": error]
    }

    private func reply(_ id: Any, result: [String: Any], output: FileHandle) {
        write(["jsonrpc": "2.0", "id": id, "result": result], output: output)
    }

    private func write(_ object: [String: Any], output: FileHandle) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        writeLock.lock(); defer { writeLock.unlock() }
        try? output.write(contentsOf: data)
    }
}

/// A flag set from the supervisor's start callback.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var why = ""
    func set() { lock.lock(); on = true; lock.unlock() }
    func fail(_ text: String) { lock.lock(); why = text; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
    var error: String { lock.lock(); defer { lock.unlock() }; return why }
}

/// A JSON-RPC id carried to another thread.
private final class IDBox: @unchecked Sendable {
    let id: Any
    init(_ id: Any) { self.id = id }
}
