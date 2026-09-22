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

    /// Runs a user's own command in zsh from the home folder.
    static func run(_ command: CustomCommand) async throws {
        _ = try await capture(["/bin/zsh", "-lc", command.command], currentDirectory: NSHomeDirectory())
    }

    /// Local TCP listeners owned by this user. Empty when lsof finds none.
    static func listeningPorts() async -> [ListeningPort] {
        let output = (try? await capture(["/usr/sbin/lsof"] + ListeningPorts.lsofArguments, allowFailure: true)) ?? ""
        return ListeningPorts.parse(output)
    }

    /// Asks a process to quit with SIGTERM.
    static func stop(_ listener: ListeningPort) throws {
        guard kill(listener.pid, SIGTERM) == 0 else {
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

    private static func capture(_ step: [String], currentDirectory: String? = nil, allowFailure: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: step[0])
            process.arguments = Array(step.dropFirst())
            if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if finished.terminationStatus == 0 || allowFailure {
                    continuation.resume(returning: stdout)
                } else {
                    let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                    let name = (step[0] as NSString).lastPathComponent
                    continuation.resume(throwing: Failure(text: line.isEmpty ? "\(name) failed with code \(finished.terminationStatus)." : line))
                }
            }
            do { try process.run() } catch {
                continuation.resume(throwing: Failure(text: "\((step[0] as NSString).lastPathComponent) could not start."))
            }
        }
    }
}

/// A command the user writes in Settings › Search. Jev sees only its name.
struct CustomCommand: Codable, Identifiable, Equatable, Hashable {
    var id = UUID().uuidString
    var name: String
    var command: String
}
