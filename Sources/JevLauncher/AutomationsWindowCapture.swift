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
            + AutomationsViewModel.Section.allCases.map { ("automations-empty-\($0.rawValue)", AnyView(AutomationsWindow.snapshotView(demo: false, section: $0))) }
            + AutomationTemplate.allCases.map { ("automations-editor-\($0)", AnyView(AutomationsWindow.snapshotEditor($0).frame(width: 720, height: 820))) }
        Task { @MainActor in
            await captureRealWindow(to: directory)
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
                capture(window, to: (directory as NSString).appendingPathComponent(name + ".png"))
                window.orderOut(nil)
            }
            print("Saved \(shots.count) captures to \(directory)")
            NSApp.terminate(nil)
        }
    }

    /// Opens the real `AutomationsWindow` through `show`, as Hyper+A does, with demo data and a stale,
    /// too-small saved frame. Then hides the sidebar, closes, and opens it again.
    private static func captureRealWindow(to directory: String) async {
        let name = "JevcastAutomationsCapture"
        let key = "NSWindow Frame " + name
        UserDefaults.standard.set("0 240 420 300 0 0 1800 1130 ", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let model = AutomationsViewModel(center: nil, quill: nil, demo: AutomationsDemoData.make())
        let controller = AutomationsWindow(model: model, autosaveName: name)
        controller.show(automationID: "desktop-tidy-demo", runID: nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let window = controller.window else { return }
        FileHandle.standardError.write(Data("Real window frame: \(window.frame) content: \(window.contentView?.frame ?? .zero) screen: \(window.screen?.visibleFrame ?? .zero)\n".utf8))
        capture(window, to: (directory as NSString).appendingPathComponent("automations-window-open.png"))
        model.columnVisibility = .detailOnly
        try? await Task.sleep(nanoseconds: 800_000_000)
        controller.close()
        controller.show(automationID: nil, runID: nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        capture(window, to: (directory as NSString).appendingPathComponent("automations-window-reopen.png"))
        controller.close()
    }

    /// A screen image when Screen Recording access allows it; otherwise the app draws the window itself.
    private static func capture(_ window: NSWindow, to path: String) {
        try? FileManager.default.removeItem(atPath: path)
        screenshot(window, to: path)
        if !FileManager.default.fileExists(atPath: path) { save(window, to: path) }
    }

    /// A true screen image of the window through `screencapture`, which draws materials and sidebars as
    /// they look. Needs Screen Recording access for Jevcast; without it the file is not written.
    private static func screenshot(_ window: NSWindow, to path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try? process.run()
        process.waitUntilExit()
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
