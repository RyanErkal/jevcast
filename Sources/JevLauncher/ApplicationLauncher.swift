import AppKit

@MainActor
protocol ApplicationLaunching {
    func open(_ app: AppEntry, completion: @escaping @MainActor (Result<Void, Error>) -> Void)
}

@MainActor
struct ApplicationLauncher: ApplicationLaunching {
    func open(_ app: AppEntry, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let url = URL(fileURLWithPath: app.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Frontmost.openApplication(at: url, configuration: configuration) { running, error in
            Task { @MainActor in
                if let error { completion(.failure(error)); return }
                guard let running, running.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else {
                    completion(.failure(LauncherError("macOS opened a different copy of this app. Check its location in Finder.")))
                    return
                }
                // Allow time for initial activation. A slow foreground transition
                // does not make a live app returned by LaunchServices a failed launch.
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while running.activationPolicy == .regular && !running.isActive && !running.isTerminated && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if CommandLine.arguments.contains("--trace-interaction") {
                    print("[Jev interaction] app-open pid=\(running.processIdentifier) active=\(running.isActive) terminated=\(running.isTerminated)")
                    fflush(stdout)
                }
                guard !running.isTerminated else {
                    completion(.failure(LauncherError("\(app.name) closed while it was opening. Try opening it from Finder.")))
                    return
                }
                completion(.success(()))
            }
        }
    }
}
