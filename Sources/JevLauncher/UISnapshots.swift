import AppKit
import Combine

/// `--snapshot-ui <dir>` renders the launcher and each Settings pane to PNG
/// from the app's own view hierarchy, then quits. Layout only; window
/// material, shadow, and toolbar chrome are not part of the capture. The
/// launcher capture is the content at its own height, over the window
/// background colour, so a panel that fails to shrink shows in the log line.
@MainActor
enum UISnapshots {
    static var directory: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot-ui"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func write(_ view: NSView, name: String, to directory: String) {
        view.layoutSubtreeIfNeeded()
        guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        view.cacheDisplay(in: view.bounds, to: cached)
        output.size = cached.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        let bounds = NSRect(origin: .zero, size: cached.size)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        cached.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = output.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}

/// A launcher for `--snapshot-ui` with its own preferences and a fake
/// pasteboard, so captures do not depend on, or change, the user's favourites,
/// recent items, or clipboard. Files come from the home folder, or with
/// `--demo` from invented sample files, with Apple apps only.
@MainActor
final class LauncherSnapshotRig {
    static let suite = "JevLauncher.snapshots"
    /// The pre-26 material: a view capture draws glass vibrancy as flat black and white.
    let panel = LauncherPanel(glass: false)
    let model: LauncherModel
    private let defaults: UserDefaults
    private let pasteboard = SnapshotPasteboard()
    private let demo: Bool

    init(catalogue: AppCatalogue, demo: Bool) {
        self.demo = demo
        defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false
        preferences.jevEnabled = false
        var catalogue = catalogue
        var files: FileSearching?
        if demo {
            catalogue = AppCatalogue(loadCache: false, roots: DemoData.appRoots, persistsCache: false)
            catalogue.refresh(extra: [])
            files = DemoData.makeFileSearch()
            LauncherModel.displayHome = DemoData.home
            preferences.fileFolders = ["Documents", "Downloads", "Desktop"].map { NSHomeDirectory() + "/" + $0 }
        }
        // Fresh Luna state, so captures never show this Mac's key or activity.
        model = LauncherModel(preferences: preferences, catalogue: catalogue, files: files, keys: JevKeyCache(key: nil),
                              clipboard: ClipboardHistory(pasteboard: pasteboard), lunaKeys: JevKeyCache(key: nil),
                              lunaLog: LunaActivityLog(defaults: defaults))
        panel.acceptsKey = false; panel.alphaValue = 0; panel.ignoresMouseEvents = true
        panel.host(LauncherView(model: model, speech: model.speech, catalogue: catalogue, actions: {}))
        model.makePage = { [unowned model] id in LauncherPages.make(id, model: model, links: .init(), snapshot: true) }
        viewSizeWatch = model.$page.map { $0 != nil }.removeDuplicates().sink { [panel] wide in panel.setViewSize(wide) }
    }
    private var viewSizeWatch: AnyCancellable?
    func open() {
        model.begin(); model.pauseListening()
        // Window rows name the frontmost app; a demo names a neutral one.
        if demo { model.overrideTargetName("Notes") }
        panel.place(on: NSScreen.main)
        panel.orderFrontRegardless()
    }
    /// One favourite app and two recent items, as after a few days of use.
    func seedSuggestions() {
        let preferences = model.preferences
        let apps = model.catalogue.entries
        if let finder = apps.first(where: { $0.name == "Finder" }) { preferences.favourites = [finder.id] }
        preferences.record("window:left-half", query: "")
        if let safari = apps.first(where: { $0.name == "Safari" }) { preferences.record(safari.id, query: "") }
        model.rebuild()
    }
    func seedClipboard() {
        for text in DemoData.clipboard {
            pasteboard.text = text; pasteboard.changeCount += 1
            model.clipboard.poll()
        }
    }
    func close() {
        model.closeAllViews(); model.end(); panel.orderOut(nil)
    }
    /// Demo Settings captures still read these preferences, so removal waits for the last capture.
    func removePreferences() {
        defaults.removePersistentDomain(forName: Self.suite)
    }
}

@MainActor private final class SnapshotPasteboard: PasteboardReading {
    var changeCount = 0
    var types = ["public.utf8-plain-text"]
    var text: String?
    func string() -> String? { text }
    func write(_ text: String) -> Int { self.text = text; changeCount += 1; return changeCount }
}
