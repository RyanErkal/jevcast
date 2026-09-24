import AppKit

/// Opens apps, files, and links so that what opens comes to the front. Since macOS 14, an app
/// that opens another app must yield activation to it, or the other app can stay behind the
/// window you were using. Each call yields to the app that will handle it, then activates it.
@MainActor
enum Frontmost {
    /// The app that opens `url`: the app itself for a `.app` bundle, or its default handler.
    static func handler(for url: URL) -> URL? {
        url.pathExtension == "app" ? url : NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    static func bundleID(of appURL: URL?) -> String? { appURL.flatMap { Bundle(url: $0)?.bundleIdentifier } }

    /// Lets `bundleID` take the front, then gives up the front so it can.
    static func yield(to bundleID: String?) {
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
    }

    /// Brings the app to the front now, and once more after it has had a moment to open windows.
    static func activate(_ bundleID: String?) {
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        func bring() { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate() }
        bring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { bring() }
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        let id = bundleID(of: handler(for: url))
        yield(to: id)
        guard NSWorkspace.shared.open(url) else { return false }
        activate(id)
        return true
    }

    @discardableResult
    static func open(_ urls: [URL], withApplicationAt app: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication {
        let id = bundleID(of: app)
        yield(to: id)
        configuration.activates = true
        let running = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
        activate(id)
        return running
    }

    static func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration,
                                completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)? = nil) {
        let id = bundleID(of: url)
        yield(to: id)
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, error in
            Task { @MainActor in if error == nil { activate(id) } }
            completionHandler?(running, error)
        }
    }

    @discardableResult
    static func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication {
        let id = bundleID(of: url)
        yield(to: id)
        configuration.activates = true
        let running = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        activate(id)
        return running
    }

    /// Shows files in Finder, in front.
    static func reveal(_ urls: [URL]) {
        yield(to: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        activate("com.apple.finder")
    }
}
