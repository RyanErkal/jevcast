import AppKit
import LauncherCore

/// `--notch-demo`: the notch panel alone, with invented alerts on a fixed timeline, then quit.
/// `main` starts it before the instance check, so it builds no launcher, menu, preferences, stores, Keychain access,
/// hotkeys, Hyper key, or runner, and it never hands off to or changes the installed copy. Buttons only print.
@MainActor
enum NotchDemo {
    struct Step {
        let at: TimeInterval
        let label: String
        let alerts: [NotchAlert]
    }

    static let quitAt: TimeInterval = 120

    /// Each stage holds long enough to click and inspect: one running, then three, then work that needs the user.
    static func timeline(start: Date) -> [Step] {
        func running(_ id: String, _ title: String, _ symbol: String, _ accent: AutomationAccent, ago: TimeInterval,
                     stage: String?) -> NotchAlert {
            NotchAlert(id: "running:\(id)/demo", kind: .running, symbol: symbol, accent: accent.rawValue, title: title,
                       message: "Running", detail: stage, started: start.addingTimeInterval(-ago),
                       lastSuccess: start.addingTimeInterval(-3 * 3600),
                       actions: [.init("Details", id: NotchAlert.detailsAction),
                                 .init("Cancel Run", id: "cancel", role: .destructive, menuOnly: true)],
                       automationID: id, runID: "demo")
        }
        return [
            Step(at: 0, label: "one running", alerts: [
                running("sample-metrics", "Sample metrics refresh", "chart.line.uptrend.xyaxis", .indigo, ago: 42, stage: "Data fetched")
            ]),
            Step(at: 30, label: "three running", alerts: [
                running("sample-backup", "Documents backup", "externaldrive", .teal, ago: 12, stage: nil),
                running("sample-sync", "Sample data sync", "arrow.triangle.2.circlepath", .red, ago: 5, stage: nil)
            ]),
            Step(at: 60, label: "a review", alerts: [
                NotchAlert(id: "demo-review", kind: .review, symbol: "chart.bar.xaxis", accent: AutomationAccent.purple.rawValue,
                           title: "Weekly sample report", message: RunEngine.needsReviewPrefix + "Sample weekly summary",
                           actions: [.init("Review", id: "review", primary: true), .init("Later", id: "later")])
            ]),
            Step(at: 80, label: "a question joins it", alerts: [
                NotchAlert(id: "demo-question", kind: .question, symbol: "menubar.dock.rectangle",
                           accent: AutomationAccent.orange.rawValue, title: "Desktop tidy",
                           message: "Which folder should the screenshots go to?",
                           actions: [.init("Reply…", id: NotchAlert.replyAction), .init("Later", id: "later")],
                           choices: ["Archive", "Pictures"], allowsReply: true)
            ])
        ]
    }

    /// Runs its own application loop with an accessory policy: no Dock icon, no menu-bar item, no main menu.
    static func run() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func start() {
        let notch = NotchAlertController.shared
        func log(_ text: String) { print("[Jev notch] \(text)"); fflush(stdout) }
        // The only handler: nothing is answered, approved, cancelled, or opened.
        notch.onAction = { alert, action in log("\(alert.id) \(action)") }
        let steps = timeline(start: Date())
        log("timeline: " + steps.map { "\(Int($0.at)) s \($0.label)" }.joined(separator: " · ") + " · \(Int(quitAt)) s quit")
        for step in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.at) {
                log(step.label)
                for alert in step.alerts { notch.show(alert) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + quitAt) { log("quit"); NSApp.terminate(nil) }
    }

    @MainActor private final class Delegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) { NotchDemo.start() }
    }
}
