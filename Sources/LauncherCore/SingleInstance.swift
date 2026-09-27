import Foundation

/// Decides at launch whether this copy of Jevcast runs. Pure, so tests cover it.
public enum SingleInstance {
    public enum Decision: Equatable, Sendable {
        /// The only copy: take the lock and run normally.
        case run
        /// A diagnostic or snapshot run: no lock, no watchers, no runner registration, no Hyper remap.
        case diagnostic
        /// Another copy is running: ask it to show the launcher and exit.
        case handOff
    }

    /// Flags that run a one-off tool or capture instead of the app.
    public static let diagnosticFlags: Set<String> = ["--snapshot-ui", "--capture-automations", "--hyper-led-test",
                                                     "--notch-demo", "--store-jev-key", "--cleanup"]

    public static func isDiagnostic(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { diagnosticFlags.contains($0) || $0.hasPrefix("--diagnose") }
    }

    /// - Parameters:
    ///   - otherProcesses: running apps with the same bundle ID, excluding this process.
    ///   - lockAcquired: false when another copy holds the lock file, such as a copy from another folder.
    public static func decide(arguments: [String], otherProcesses: Int, lockAcquired: Bool) -> Decision {
        if isDiagnostic(arguments) { return .diagnostic }
        return otherProcesses == 0 && lockAcquired ? .run : .handOff
    }
}
