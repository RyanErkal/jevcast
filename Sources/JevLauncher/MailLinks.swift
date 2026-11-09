import AppKit
import LauncherCore
import SwiftUI

/// Opens `mailto:` links as a new message in Jevcast. The app sets `compose` at launch.
@MainActor
enum MailLinkRouter {
    /// Starts a new message from the link. False when Mail is not set up here, so the link goes
    /// to the Mac's default mail app.
    static var compose: ((MailtoLink) -> Bool)?

    /// Opens a link clicked in a message: a mail address in Jevcast, anything else in the browser.
    static func open(_ url: URL) {
        if url.scheme?.lowercased() == "mailto", let link = MailtoLink(url), compose?(link) == true { return }
        Frontmost.open(url)
    }
}

/// The Mac's default mail app: which app opens when a mail address is clicked anywhere.
/// Jevcast changes it only when the user clicks the button in Settings › Mail.
@MainActor
enum DefaultMailApp {
    static var current: URL? { URL(string: "mailto:").flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) }
    static var isJevcast: Bool {
        guard let current else { return false }
        return current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            || Bundle(url: current)?.bundleIdentifier == AppIdentity.bundleID
    }
    static var currentName: String {
        current.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "None"
    }
    static func makeJevcastDefault() async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
    }
}

/// Settings › Mail: make Jevcast open mail links. The row states the current app and changes nothing by itself.
struct DefaultMailAppSection: View {
    @State private var name = DefaultMailApp.currentName
    @State private var isDefault = DefaultMailApp.isJevcast
    @State private var problem: String?

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isDefault ? "Jevcast opens mail links" : "Mail links open in " + name)
                    Text("A mail address clicked in another app starts a new message in the default mail app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Make Jevcast the Default") {
                    Task { @MainActor in
                        do { try await DefaultMailApp.makeJevcastDefault(); problem = nil }
                        catch { problem = "macOS did not change the default mail app: " + error.localizedDescription }
                        name = DefaultMailApp.currentName; isDefault = DefaultMailApp.isJevcast
                    }
                }
                .disabled(isDefault)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        } header: { Text("Default mail app") }
    }
}
