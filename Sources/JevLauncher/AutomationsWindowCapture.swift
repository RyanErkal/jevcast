import AppKit
import SwiftUI

/// `--capture-automations <dir>`: shows the Automations window with demo data on screen, section by section,
/// and saves each as a PNG, then quits. Lists only draw inside a real on-screen window, so offscreen
/// snapshots come out blank; this draws the app's own on-screen window, which needs no screen-recording permission.
@MainActor
enum AutomationsWindowCapture {
    static func run(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let shots: [(String, AnyView)] = AutomationsViewModel.Section.allCases.map { ("automations-\($0.rawValue)", AnyView(AutomationsWindow.snapshotView(demo: true, section: $0))) }
            + AutomationTemplate.allCases.map { ("automations-editor-\($0)", AnyView(AutomationsWindow.snapshotEditor($0).frame(width: 720, height: 820))) }
        Task { @MainActor in
            for (name, view) in shots {
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1240, height: 780),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let hosting = NSHostingController(rootView: view)
                hosting.sceneBridgingOptions = [.toolbars, .title]
                window.contentViewController = hosting
                window.title = "Automations"
                window.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                save(window, to: (directory as NSString).appendingPathComponent(name + ".png"))
                window.orderOut(nil)
            }
            print("Saved \(shots.count) captures to \(directory)")
            NSApp.terminate(nil)
        }
    }

    private static func save(_ window: NSWindow, to path: String) {
        // Draw the whole frame view, including the toolbar, into a bitmap. On screen, lists are laid out,
        // so this works where an offscreen render does not.
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { print("Could not capture \(path)"); return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        // Second pass through Core Animation, which also draws layer-hosted list rows.
        guard let layer = frameView.layer else { return }
        let scale = window.backingScaleFactor
        let size = NSSize(width: frameView.bounds.width * scale, height: frameView.bounds.height * scale)
        guard let layerRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: layerRep) else { return }
        context.cgContext.scaleBy(x: scale, y: scale)
        if !frameView.isFlipped { context.cgContext.translateBy(x: 0, y: frameView.bounds.height); context.cgContext.scaleBy(x: 1, y: -1) }
        layer.render(in: context.cgContext)
        try? layerRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-layers.png")))
    }
}
