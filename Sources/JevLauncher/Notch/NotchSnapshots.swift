import AppKit
import SwiftUI

/// `--snapshot-ui <dir> --demo`: each island state rendered offscreen at 2x, with invented content only.
@MainActor
enum NotchSnapshots {
    private static let notch = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 200, notchHeight: 32)
    private static let plain = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), notchWidth: 0, notchHeight: 0)

    static func writeAll(to directory: String) {
        let started = Date().addingTimeInterval(-84)
        let running = NotchAlert(id: "demo-running", kind: .running, symbol: "chart.bar.xaxis", title: "Sample metrics refresh",
                                 message: "Running", detail: "Step 2 of 3: reading the sample source", progress: 0.62, started: started,
                                 actions: [.init("Cancel", id: "cancel", role: .destructive), .init("Open", id: "open")])
        var counts = NotchAlert.ApprovalCounts(); counts.moves = 12; counts.trash = 3
        let approval = NotchAlert(id: "demo-approval", kind: .approval, symbol: "folder.badge.gearshape", title: "Downloads tidy",
                                  message: counts.summary, actions: [
                                    .init("Approve all", id: "approveAll", primary: true), .init("Review", id: "review"),
                                    .init("Later", id: "later")], counts: counts)
        let question = NotchAlert(id: "demo-question", kind: .question, symbol: "questionmark.bubble", title: "Desktop tidy",
                                  message: "Which folder should the screenshots go to?",
                                  actions: [.init("Reply…", id: NotchAlert.replyAction), .init("Open", id: "answer"),
                                            .init("Later", id: "later")],
                                  choices: ["Archive", "Pictures", "Leave them"], allowsReply: true)
        let failure = NotchAlert(id: "demo-failure", kind: .failure, symbol: "chart.bar.xaxis", title: "Sample report",
                                 message: "The sample source did not answer.", detail: "Exit 1 · 3 tries",
                                 actions: [.init("Retry", id: "retry", primary: true), .init("Open", id: "open"),
                                           .init("Dismiss", id: "dismiss")])
        let success = NotchAlert(id: "demo-success", kind: .success, symbol: "checkmark.circle.fill", title: "Desktop tidy",
                                 message: "Moved 12 files. Undo is in Automations.", actions: [.init("Open", id: "open", primary: true)])
        let stack = NotchQueue.stack([question, approval, failure, running])
        let shots: [(String, NotchAlert, NotchMode, NotchGeometry, String?)] = [
            ("notch-pill-running", running, .compact, notch, nil),
            ("notch-detail-running", running, .detail, notch, nil),
            ("notch-card-approval", approval, .card, notch, nil),
            ("notch-card-question", question, .card, notch, nil),
            ("notch-reply", question, .reply, notch, "demo-question"),
            ("notch-card-failure", failure, .card, notch, nil),
            ("notch-card-success", success, .card, notch, nil),
            ("notch-stack-card", stack, .card, notch, nil),
            ("notch-stack-list", stack, .detail, notch, nil),
            ("notch-plain-pill", running, .compact, plain, nil),
            ("notch-plain-card", approval, .card, plain, nil),
            ("notch-plain-list", stack, .detail, plain, nil)
        ]
        for (name, alert, mode, geometry, target) in shots {
            write(scene(alert, mode: mode, geometry: geometry, replyTarget: target), name: name, to: directory)
        }
    }

    /// A dark desktop with a menu bar, so the island reads in context. The notch is drawn as black.
    private static func scene(_ alert: NotchAlert, mode: NotchMode, geometry: NotchGeometry, replyTarget: String?) -> some View {
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
