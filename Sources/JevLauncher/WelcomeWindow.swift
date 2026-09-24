import AppKit
import SwiftUI

/// First-launch guide. A menu-bar app shows no window of its own, and a full
/// menu bar can hide its icon behind the notch, so this is the first contact.
/// It opens once by itself; Help › Welcome Guide opens it again.
@MainActor
final class WelcomeWindow: NSWindowController, NSWindowDelegate {
    static let width: CGFloat = 520

    init(preferences: Preferences, model: LauncherModel, status: LauncherStatus, changed: @escaping () -> Void, openSettings: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to \(AppIdentity.name)"
        super.init(window: window)
        let view = WelcomeView(preferences: preferences, model: model, speech: model.speech, status: status, changed: changed,
                               openSettings: { [weak self] in self?.close(); openSettings() },
                               done: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view.frame(width: Self.width))
        window.contentView = hosting
        // A grouped Form scrolls, so measure the same view unscrolled at its ideal height.
        // A short screen gets a shorter window, and the form scrolls inside it.
        let probe = NSHostingView(rootView: view.scrollDisabled(true).frame(width: Self.width).fixedSize(horizontal: false, vertical: true))
        let screen = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        window.setContentSize(NSSize(width: Self.width, height: min(ceil(probe.fittingSize.height), screen)))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct WelcomeView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: LauncherModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var status: LauncherStatus
    let changed: () -> Void
    let openSettings: () -> Void
    let done: () -> Void
    @State private var opened = false
    private let location = InstallLocation.warning()

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                if let location {
                    Section {
                        Label(location, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Section("Open the launcher") {
                    Picker("Shortcut", selection: $preferences.hotkey) {
                        ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                    }
                    Label(tryItText, systemImage: opened ? "checkmark.circle.fill" : "keyboard")
                        .font(.callout)
                        .foregroundStyle(opened ? Color.green : Color.secondary)
                }
                Section("Move windows (optional)") {
                    PermissionRow(permission: .accessibility) { model.windows.requestPermission() }
                }
                Section("Voice (optional)") {
                    Toggle("Listen when the launcher opens", isOn: voice)
                    Text("Turning this on asks for Microphone and Speech Recognition access. Speech becomes text on this Mac. Audio is not saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Startup and updates") {
                    LoginItemRows(preferences: preferences)
                    Toggle("Check for updates automatically", isOn: $preferences.checksForUpdates)
                }
            }
            .formStyle(.grouped)
            // One background for header, form, and footer.
            .scrollContentBackground(.hidden)
            footer
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherDidOpen)) { _ in opened = true }
        .onChange(of: preferences.hotkey) { _, _ in opened = false; changed() }
    }

    /// Turning voice on asks for both permissions the first time; after a denial, Settings › Voice has the buttons.
    private var voice: Binding<Bool> {
        Binding(get: { preferences.voiceEnabled }, set: { enabled in
            preferences.voiceEnabled = enabled
            if enabled && (Permission.microphone.isUndetermined || Permission.speech.isUndetermined) {
                Task { await speech.requestPermissions() }
            }
        })
    }

    private var tryItText: String {
        if let message = status.launcherHotkeyMessage { return message }
        return opened ? "It works. Press Escape to close the launcher." : "Press \(preferences.hotkey.title) now to try it."
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
            Text("Welcome to \(AppIdentity.name)").font(.title2.weight(.semibold))
            Text("Open apps, find files, do quick sums, and arrange windows from the keyboard.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 2)
    }

    private var footer: some View {
        HStack {
            Button("Open Settings", action: openSettings)
            Spacer()
            Button("Done", action: done).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
    }
}
