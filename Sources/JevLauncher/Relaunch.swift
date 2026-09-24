import AppKit

/// Starts a fresh copy of Jevcast, then quits this one. macOS applies Full Disk Access only to a new start.
@MainActor
enum Relaunch {
    static func now() {
        // The new copy waits a moment, so this copy has quit before it starts. The path is an argument, not script text.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "jevcast", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
