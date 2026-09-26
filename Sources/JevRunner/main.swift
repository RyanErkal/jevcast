import AppKit
import Foundation
import LauncherCore

// jevcast-runner: the background scheduler launchd keeps alive. See docs/plans/2026-09-26-automations.md (B3).
// `--root <dir>` uses another store folder (for manual checks).

var root = AutomationStore.defaultRoot
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--root"), i + 1 < args.count { root = URL(fileURLWithPath: args[i + 1], isDirectory: true) }

guard let lockFD = SingleInstance.acquire(root: root) else {
    log("Another runner is active. Exiting.")
    // Exit 0 so launchd's KeepAlive does not restart us in a tight loop while the other copy runs.
    sleep(10)
    exit(0)
}

let runner = Runner(store: AutomationStore(root: root))
let signalObserver = AutomationSignal.observe { runner.poke() }
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    runner.poke()
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let stopSources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        runner.shutdown {
            _ = lockFD
            exit(0)
        }
    }
    source.resume()
    return source
}

runner.start()
withExtendedLifetime((signalObserver, wakeObserver, stopSources)) {
    RunLoop.main.run()
}
