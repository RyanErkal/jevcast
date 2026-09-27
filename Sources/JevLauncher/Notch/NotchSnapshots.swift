import AppKit
import SwiftUI

/// `--snapshot-ui <dir> --demo`: each island state rendered offscreen at 2x, with invented content only.
@MainActor
enum NotchSnapshots {
    private static let notch = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 200, notchHeight: 32)
    private static let plain = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), notchWidth: 0, notchHeight: 0)

    static func writeAll(to directory: String) {
        let started = Date().addingTimeInterval(-84)
        let shots: [(String, NotchPresentation, NotchMode, NotchGeometry)] = [
            ("notch-compact-running",
             NotchPresentation(phase: .running, symbol: "chart.bar.xaxis", title: "Sample metrics refresh", message: "Fetching sample data",
                               progress: 0.62, startedAt: started, actions: [.init("Stop", id: "stop")]), .compact, notch),
            ("notch-expanded-running",
             NotchPresentation(phase: .running, symbol: "chart.bar.xaxis", title: "Sample metrics refresh", message: "Step 2 of 3: fetching sample data",
                               progress: 0.62, startedAt: started, actions: [.init("Stop", id: "stop")]), .expanded, notch),
            ("notch-expanded-approval",
             NotchPresentation(phase: .approval, symbol: "folder.badge.gearshape", title: "Desktop tidy",
                               message: "Nothing moves until you approve.", detail: "12 files to move · 3 to Trash",
                               actions: [.init("Later", id: "later"), .init("Review", id: "review", primary: true)]), .expanded, notch),
            ("notch-question",
             NotchPresentation(phase: .question, symbol: "text.bubble", title: "Weekly notes digest",
                               message: "Where should this week's digest go?",
                               actions: [.init("Notes", id: "choice-0", primary: true), .init("Documents", id: "choice-1"),
                                         .init("Ask later", id: "later")]), .expanded, notch),
            ("notch-failure",
             NotchPresentation(phase: .failure, symbol: "chart.bar.xaxis", title: "Sample metrics refresh",
                               message: "The sample source did not answer.", detail: "Exit 1 · 3 tries",
                               actions: [.init("Open", id: "open"), .init("Retry", id: "retry", primary: true)]), .expanded, notch),
            ("notch-success",
             NotchPresentation(phase: .success, symbol: "checkmark.circle.fill", title: "Desktop tidy",
                               message: "Moved 12 files. Undo is in Automations.",
                               actions: [.init("Open", id: "open", primary: true)]), .expanded, notch),
            ("notch-stack-pill",
             NotchPresentation(phase: .approval, symbol: "bell.badge", title: "3 automations need you",
                               message: "Open Automations to see them.", stackCount: 3,
                               actions: [.init("Later", id: "later"), .init("Open", id: "open", primary: true)]), .expanded, plain)
        ]
        for (name, p, mode, geometry) in shots { write(scene(p, mode: mode, geometry: geometry), name: name, to: directory) }
    }

    /// A dark desktop with a menu bar, so the island reads in context. The notch is drawn as black.
    private static func scene(_ p: NotchPresentation, mode: NotchMode, geometry: NotchGeometry) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.20, green: 0.24, blue: 0.36), Color(red: 0.42, green: 0.36, blue: 0.48)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Color.black.opacity(0.22)).frame(height: geometry.hasNotch ? geometry.notchHeight : 24)
            if geometry.hasNotch {
                NotchShape(bottomRadius: 10, topFlare: 7).fill(Color.black).frame(width: geometry.notchWidth, height: geometry.notchHeight)
            }
            NotchIsland(p: p, geometry: geometry, mode: mode, action: { _ in })
                .padding(.top, geometry.hasNotch ? 0 : 24)
        }
        .frame(width: 520, height: 200)
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
