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
    static func capture(_ step: [String], currentDirectory: String? = nil, allowFailure: Bool = false) async throws -> String {
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
                do { try process.run() } catch {
                    continuation.resume(throwing: Failure(text: "\(name) could not start."))
                    return
                }
                let errors = DispatchGroup()
                nonisolated(unsafe) var errorData = Data()
                errors.enter()
                DispatchQueue.global(qos: .utility).async { errorData = err.fileHandleForReading.readDataToEndOfFile(); errors.leave() }
                let outputData = out.fileHandleForReading.readDataToEndOfFile()
                errors.wait()
                process.waitUntilExit()
                let stdout = String(decoding: outputData, as: UTF8.self)
                if process.terminationStatus == 0 || allowFailure {
                    continuation.resume(returning: stdout)
                } else {
                    let line = String(decoding: errorData, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                    continuation.resume(throwing: Failure(text: line.isEmpty ? "\(name) failed with code \(process.terminationStatus)." : line))
                }
            }
        }
    }
}
