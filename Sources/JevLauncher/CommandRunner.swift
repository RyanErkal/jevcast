import Foundation
import LauncherCore

/// Runs built-in commands, the user's own commands, and port lookups off the main thread.
/// Built-in steps run directly with fixed arguments. Only a command the user wrote in
/// Settings runs through a shell. Nothing typed, spoken, or chosen by Jev becomes command text.
enum CommandRunner {
    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Runs every step in order and returns the last step's standard output.
    static func run(_ command: SystemCommand) async throws -> String {
        if command.output == .background, let step = command.steps.first {
            try launch(step)
            return ""
        }
        var output = ""
        for step in command.steps { output = try await capture(step) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a user's own command in zsh from the home folder and returns its trimmed output.
    /// Typed input never becomes script text: "{input}" becomes "$1", and the input is passed as that argument.
    static func run(_ command: CustomCommand, input: String? = nil) async throws -> String {
        let script = command.command.replacingOccurrences(of: CustomCommand.inputPlaceholder, with: "\"$1\"")
        let output = try await capture(["/bin/zsh", "-lc", script, "jevcast", input ?? ""], currentDirectory: NSHomeDirectory())
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs an Apple Shortcut by the exact name that `shortcuts list` returned.
    static func runShortcut(_ name: String) async throws {
        _ = try await capture(["/usr/bin/shortcuts", "run", name])
    }

    /// The names of the user's Shortcuts, or an empty list when the tool is missing.
    static func shortcutNames() async -> [String] {
        let output = (try? await capture(["/usr/bin/shortcuts", "list"], allowFailure: true)) ?? ""
        return output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Local TCP listeners owned by this user. Empty when lsof finds none.
    static func listeningPorts() async -> [ListeningPort] {
        let output = (try? await capture(["/usr/sbin/lsof"] + ListeningPorts.lsofArguments, allowFailure: true)) ?? ""
        return ListeningPorts.parse(output)
    }

    /// CPU, memory, uptime, command line, and working folder for each PID, from `ps` and `lsof`.
    static func processDetails(_ pids: [Int32]) async -> [Int32: ProcessSnapshot] {
        guard !pids.isEmpty else { return [:] }
        async let stats = try? capture(["/bin/ps"] + ProcessSnapshots.statsArguments(pids), allowFailure: true)
        async let executables = try? capture(["/bin/ps"] + ProcessSnapshots.executableArguments(pids), allowFailure: true)
        async let commandLines = try? capture(["/bin/ps"] + ProcessSnapshots.commandLineArguments(pids), allowFailure: true)
        async let folders = try? capture(["/usr/sbin/lsof"] + ProcessSnapshots.folderArguments(pids), allowFailure: true)
        return ProcessSnapshots.parse(stats: await stats ?? "", executables: await executables ?? "",
                                      commandLines: await commandLines ?? "", folders: await folders ?? "")
    }

    /// Asks a process to quit with SIGTERM, or ends it at once with SIGKILL when `force` is set.
    static func stop(_ listener: ListeningPort, force: Bool = false) throws {
        guard kill(listener.pid, force ? SIGKILL : SIGTERM) == 0 else {
            throw Failure(text: errno == EPERM
                ? "\(listener.command) belongs to another user and cannot be stopped from here."
                : "\(listener.command) is no longer running.")
        }
    }

    private static func launch(_ step: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: step[0])
        process.arguments = Array(step.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure(text: "\(step[0]) could not start.") }
    }

    /// Runs one step and returns its standard output. Both pipes are read while the
    /// process runs, so a command with a lot of output cannot fill a pipe and stall.
    /// Cancelling the task, or passing `timeout`, ends the process.
    static func capture(_ step: [String], currentDirectory: String? = nil, allowFailure: Bool = false, timeout: TimeInterval? = nil,
                        acceptedExitCodes: Set<Int32> = [0], requireEmptyStderr: Bool = false) async throws -> String {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: step[0])
                    process.arguments = Array(step.dropFirst())
                    if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
                    let out = Pipe(), err = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    process.standardInput = FileHandle.nullDevice
                    let name = (step[0] as NSString).lastPathComponent
                    guard box.start(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do { try process.run() } catch {
                        continuation.resume(throwing: Failure(text: "\(name) could not start."))
                        return
                    }
                    // A cancel that came between start and run found nothing running yet.
                    if box.cancelled { process.terminate() }
                    let pid = process.processIdentifier
                    box.noteStarted(pid)
                    if let timeout { box.armTimeout(pid, after: timeout) }
                    let errors = DispatchGroup()
                    nonisolated(unsafe) var errorData = Data()
                    errors.enter()
                    DispatchQueue.global(qos: .utility).async { errorData = err.fileHandleForReading.readDataToEndOfFile(); errors.leave() }
                    let outputData = out.fileHandleForReading.readDataToEndOfFile()
                    errors.wait()
                    process.waitUntilExit()
                    let stdout = String(decoding: outputData, as: UTF8.self)
                    if box.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if box.timedOut {
                        continuation.resume(throwing: Failure(text: "\(name) took too long and was stopped."))
                    } else if requireEmptyStderr && !errorData.isEmpty {
                        continuation.resume(throwing: Failure(text: "\(name) could not verify the full result."))
                    } else if (process.terminationReason == .exit && acceptedExitCodes.contains(process.terminationStatus)) || allowFailure {
                        continuation.resume(returning: stdout)
                    } else {
                        let line = String(decoding: errorData, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                        continuation.resume(throwing: Failure(text: line.isEmpty ? "\(name) failed with code \(process.terminationStatus)." : line))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// The running process of one `capture`, so cancelling the task can end it.
private final class ProcessBox: @unchecked Sendable {
    /// Its own queue, so a busy global pool cannot hold the time limit past the process's own exit.
    private let timeoutQueue = DispatchQueue(label: "jevcast.command-timeout", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var pid: pid_t = 0
    private var _cancelled = false
    private var _timedOut = false
    var cancelled: Bool { lock.withLock { _cancelled } }
    var timedOut: Bool { lock.withLock { _timedOut } }
    /// Keeps the process, or returns false when the task was already cancelled.
    func start(_ process: Process) -> Bool {
        lock.withLock {
            guard !_cancelled else { return false }
            self.process = process
            return true
        }
    }
    func noteStarted(_ pid: pid_t) { lock.withLock { self.pid = pid } }
    /// Signals the pid when the time limit passes. `Process` is not thread-safe: calling
    /// `terminate()` from this queue deadlocks the pipe read on the worker thread, and the
    /// test then waits until the job's own time limit.
    func armTimeout(_ pid: pid_t, after timeout: TimeInterval) {
        timeoutQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire(pid) }
    }
    private func expire(_ pid: pid_t) {
        let current = lock.withLock { () -> pid_t? in
            guard !_cancelled, self.pid == pid, pid > 0 else { return nil }
            _timedOut = true
            return pid
        }
        guard let current else { return }
        // The process already exited, so this was not a time limit.
        if kill(current, SIGTERM) != 0 { lock.withLock { if self.pid == current { _timedOut = false } } }
    }
    func cancel() {
        let pid = lock.withLock { () -> pid_t? in _cancelled = true; return self.pid > 0 ? self.pid : nil }
        if let pid { _ = kill(pid, SIGTERM) }
    }
}
