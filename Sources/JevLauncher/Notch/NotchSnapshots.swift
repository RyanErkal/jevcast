import AppKit
import SwiftUI
import LauncherCore

/// `--snapshot-ui <dir> --demo`: each island state rendered offscreen at 2x, with invented content only.
@MainActor
enum NotchSnapshots {
    private static let notch = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 200, notchHeight: 32)
    private static let plain = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), notchWidth: 0, notchHeight: 0)

    /// Invented automations. Each has its own icon and accent, as the editor saves them.
    private enum Demo {
        static func running(_ id: String, _ title: String, symbol: String, accent: AutomationAccent, stage: StageProgress? = nil,
                            started: TimeInterval, lastSuccess: TimeInterval? = nil, now: Date) -> NotchAlert {
            NotchAlert(id: "running:\(id)/demo", kind: .running, symbol: symbol, accent: accent.rawValue, title: title,
                       message: "Running", detail: stage?.phrase, started: now.addingTimeInterval(-started),
                       lastSuccess: lastSuccess.map { now.addingTimeInterval(-$0) },
                       actions: [.init("Details", id: NotchAlert.detailsAction),
                                 .init("Cancel Run", id: "cancel", role: .destructive, menuOnly: true)],
                       automationID: id, runID: "demo")
        }
    }

    static func writeAll(to directory: String) {
        let now = Date()
        let report = Demo.running("sample-report", "Weekly sample report", symbol: "chart.bar.xaxis", accent: .purple,
                                  stage: StageProgress(phrase: "Data fetched"), started: 84, lastSuccess: 3 * 3600, now: now)
        let backup = Demo.running("sample-backup", "Documents backup", symbol: "externaldrive", accent: .teal, started: 312,
                                  lastSuccess: 26 * 3600, now: now)
        let tidy = Demo.running("sample-tidy", "Desktop tidy", symbol: "menubar.dock.rectangle", accent: .orange, started: 41, now: now)
        // A red accent on healthy work: the colour is identity, so nothing here reads as a failure.
        let sync = Demo.running("sample-sync", "Sample data sync", symbol: "arrow.triangle.2.circlepath", accent: .red, started: 19,
                                lastSuccess: 55 * 60, now: now)
        // Demo only: run records carry no retry time, so a live card says "Retrying automatically" instead.
        var retry = Demo.running("sample-metrics", "Sample metrics refresh", symbol: "chart.line.uptrend.xyaxis", accent: .indigo,
                                 started: 96, lastSuccess: 2 * 3600, now: now)
        retry.retry = NotchAlert.Retry(attempt: 1, at: now.addingTimeInterval(40))
        let hidden = Demo.running("sample-private", Automation.Kind.staged(sampleStaged).category, symbol: "doc.text.magnifyingglass",
                                  accent: .blue, stage: StageProgress(phrase: "Plan ready"), started: 23, lastSuccess: 7 * 3600, now: now)
        let multi = NotchQueue.stack([report, backup, sync, tidy])

        var counts = NotchAlert.ApprovalCounts(); counts.moves = 12; counts.trash = 3
        let approval = NotchAlert(id: "demo-approval", kind: .approval, symbol: "arrow.down.circle", accent: AutomationAccent.cyan.rawValue,
                                  title: "Downloads tidy", message: counts.summary, actions: [
                                    .init("Approve all", id: "approveAll", primary: true), .init("Review", id: "review"),
                                    .init("Later", id: "later")], counts: counts)
        let question = NotchAlert(id: "demo-question", kind: .question, symbol: "menubar.dock.rectangle",
                                  accent: AutomationAccent.orange.rawValue, title: "Desktop tidy",
                                  message: "Which folder should the screenshots go to?",
                                  actions: [.init("Reply…", id: NotchAlert.replyAction), .init("Open", id: "answer"),
                                            .init("Later", id: "later")],
                                  choices: ["Archive", "Pictures", "Leave them"], allowsReply: true)
        let failure = NotchAlert(id: "demo-failure", kind: .failure, symbol: "chart.line.uptrend.xyaxis",
                                 accent: AutomationAccent.indigo.rawValue, title: "Sample metrics refresh",
                                 message: "Failed: the sample source did not answer.",
                                 actions: [.init("Retry", id: "retry", primary: true), .init("Details", id: NotchAlert.detailsAction),
                                           .init("Dismiss", id: "dismiss")])
        // A run that stopped on an item only the user can settle: amber, Review first, and never "Done".
        let review = NotchAlert(id: "demo-review", kind: .review, symbol: "chart.bar.xaxis", accent: AutomationAccent.purple.rawValue,
                                title: "Weekly sample report", message: RunEngine.needsReviewPrefix + "Sample weekly summary",
                                actions: [.init("Review", id: "review", primary: true), .init("Later", id: "later")])
        let ready = NotchAlert(id: "demo-ready", kind: .success, symbol: "chart.bar.xaxis", accent: AutomationAccent.purple.rawValue,
                               title: "Weekly sample report", message: RunEngine.reportReadyPrefix + "Sample weekly summary",
                               actions: [.init("Open", id: "open", primary: true), .init("Dismiss", id: "dismiss")])
        let success = NotchAlert(id: "demo-success", kind: .success, symbol: "menubar.dock.rectangle",
                                 accent: AutomationAccent.orange.rawValue, title: "Desktop tidy",
                                 message: "Moved 12 files. Undo is in Automations.", actions: [.init("Open", id: "open", primary: true)])
        let stack = NotchQueue.stack([question, review, failure, approval])
        // Long names truncate on one line; six running show three icons, the count, and four rows of six.
        let long = Demo.running("sample-long", "Quarterly sample revenue reconciliation for the northern region accounts",
                                symbol: "dollarsign.circle", accent: .green, stage: StageProgress(phrase: "Analysis written"),
                                started: 1_412, lastSuccess: 5 * 86400, now: now)
        let longFailure = NotchAlert(id: "demo-long-failure", kind: .failure, symbol: "dollarsign.circle",
                                     accent: AutomationAccent.green.rawValue,
                                     title: "Quarterly sample revenue reconciliation for the northern region accounts",
                                     message: "Failed: the sample ledger export ended before the closing balance row was written.",
                                     actions: [.init("Retry", id: "retry", primary: true), .init("Details", id: NotchAlert.detailsAction),
                                               .init("Dismiss", id: "dismiss")])
        let many = NotchQueue.stack([report, backup, sync, tidy, long,
                                     Demo.running("sample-mail", "Sample inbox digest", symbol: "envelope", accent: .cyan, started: 8, now: now)])
        // Finished runs: the pill keeps the icon, and the ring becomes the outcome mark.
        func finished(_ alert: NotchAlert) -> NotchAlert { var a = alert; a.minimized = true; return a }
        var done = finished(ready); done.runID = "demo-done"
        let doneTogether = NotchQueue.stack([finished(success), done])
        let shots: [(String, NotchAlert, NotchMode, NotchGeometry, String?)] = [
            ("notch-pill-done", done, .compact, notch, nil),
            ("notch-pill-failed", finished(failure), .compact, notch, nil),
            ("notch-pill-review", finished(review), .compact, notch, nil),
            ("notch-pill-done-together", doneTogether, .compact, notch, nil),
            ("notch-pill-question", finished(question), .compact, notch, nil),
            ("notch-pill-approval", finished(approval), .compact, notch, nil),
            ("notch-plain-pill-failed", finished(failure), .compact, plain, nil),
            // One automation running: its icon and colour, one ring, no timer.
            ("notch-pill-running", report, .compact, notch, nil),
            ("notch-detail-running", report, .detail, notch, nil),
            // Several running: a few icons, the count, and one ring; the list gives each its Details.
            ("notch-pill-multi", multi, .compact, notch, nil),
            ("notch-list-multi", multi, .detail, notch, nil),
            ("notch-pill-retry", retry, .compact, notch, nil),
            ("notch-detail-retry", retry, .detail, notch, nil),
            ("notch-detail-private", hidden, .detail, notch, nil),
            ("notch-card-review", review, .card, notch, nil),
            ("notch-card-report", ready, .card, notch, nil),
            ("notch-card-approval", approval, .card, notch, nil),
            ("notch-card-question", question, .card, notch, nil),
            ("notch-reply", question, .reply, notch, "demo-question"),
            ("notch-card-failure", failure, .card, notch, nil),
            ("notch-card-success", success, .card, notch, nil),
            ("notch-stack-card", stack, .card, notch, nil),
            ("notch-stack-list", stack, .detail, notch, nil),
            ("notch-plain-pill", report, .compact, plain, nil),
            ("notch-plain-detail", report, .detail, plain, nil),
            ("notch-plain-card", approval, .card, plain, nil),
            ("notch-plain-list", multi, .detail, plain, nil)
        ]
        let more: [(String, NotchAlert, NotchMode)] = [
            ("notch-detail-longtitle", long, .detail),
            ("notch-card-longtitle", longFailure, .card),
            ("notch-pill-many", many, .compact),
            ("notch-list-many", many, .detail)
        ]
        // The surface is opaque black in every setting; Increase Contrast firms the rim and the controls.
        let contrast = NotchAccessibilityOverride(increaseContrast: true)
        let accessible: [(String, NotchAlert, NotchMode, NotchAccessibilityOverride)] = [
            ("notch-a11y-increase-contrast", stack, .detail, contrast),
            ("notch-a11y-increase-contrast-card", review, .card, contrast)
        ]
        for (name, alert, mode, geometry, target) in shots {
            write(scene(alert, mode: mode, geometry: geometry, replyTarget: target), name: name, to: directory)
        }
        for (name, alert, mode) in more {
            write(scene(alert, mode: mode, geometry: notch, replyTarget: nil), name: name, to: directory)
        }
        for (name, alert, mode, override) in accessible {
            write(scene(alert, mode: mode, geometry: notch, replyTarget: nil, override: override), name: name, to: directory)
        }
    }

    /// Only its kind is read, for the category a hidden name shows.
    private static let sampleStaged = StagedTask(
        preflight: ScriptTask(executable: "/bin/echo", workingDirectory: "/"), finish: ScriptTask(executable: "/bin/echo", workingDirectory: "/"),
        analyst: AgentTask(prompt: "", workingDirectory: "/"), claim: "sample")

    /// A dark desktop with a menu bar, so the island reads in context. The notch is drawn as black.
    /// The island draws no window-server material: its black surface and rim render offscreen as they do on screen.
    private static func scene(_ alert: NotchAlert, mode: NotchMode, geometry: NotchGeometry, replyTarget: String?,
                              override: NotchAccessibilityOverride = NotchAccessibilityOverride()) -> some View {
        let menuBar: CGFloat = geometry.hasNotch ? geometry.notchHeight : 24
        let height = menuBar + NotchStyle.size(mode, alert, geometry).height + 40
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.20, green: 0.24, blue: 0.36), Color(red: 0.42, green: 0.36, blue: 0.48)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Color.black.opacity(0.22)).frame(height: menuBar)
            if geometry.hasNotch {
                NotchShape(bottomRadius: 10, topFlare: 7).fill(Color.black).frame(width: geometry.notchWidth, height: geometry.notchHeight)
            }
            NotchIsland(alert: alert, geometry: geometry, mode: mode, replyTarget: replyTarget, liveField: false,
                        draft: replyTarget == nil ? "" : "Put them in Archive/2026")
                .padding(.top, geometry.hasNotch ? 0 : 24)
        }
        .frame(width: 520, height: height)
        .environment(\.colorScheme, .dark)
        .environment(\.notchLiveSurface, false)
        .environment(\.notchAccessibilityOverride, override)
    }

    private static func write(_ view: some View, name: String, to directory: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("[Jev snapshot] \(name) failed"); return
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        print("[Jev snapshot] \(name) \(image.width)x\(image.height)")
    }
}
