import AppKit
import SwiftUI

/// Title and one line of text at the top of each welcome step.
struct WelcomeHeading: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 4)
    }
}

struct WelcomeIntroPage: View {
    private let location = InstallLocation.warning()
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            WelcomeHeading(title: "Welcome to \(AppIdentity.name)",
                           text: "Open apps, find files, do quick sums, and arrange windows from the keyboard. This guide takes about a minute.")
            if let location {
                Label(location, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, 40)
            }
            Spacer()
        }
    }
}

struct WelcomeShortcutPage: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var status: LauncherStatus
    let changed: () -> Void
    @State private var opened = false

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeading(title: "Open the launcher", text: "One shortcut opens \(AppIdentity.name) from any app.")
            Form {
                Section {
                    Picker("Shortcut", selection: $preferences.hotkey) {
                        ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                    }
                    Label(tryItText, systemImage: opened ? "checkmark.circle.fill" : "keyboard")
                        .font(.callout)
                        .foregroundStyle(opened ? Color.green : Color.secondary)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherDidOpen)) { _ in opened = true }
        .onChange(of: preferences.hotkey) { _, _ in opened = false; changed() }
    }

    private var tryItText: String {
        if let message = status.launcherHotkeyMessage { return message }
        return opened ? "It works. Press Escape to close the launcher." : "Press \(preferences.hotkey.title) now to try it."
    }
}

/// Real queries the user can run from the guide. Each one opens the launcher with the text typed.
struct WelcomeExample: Identifiable {
    let symbol: String
    let title: String
    let query: String
    /// Window actions move the window you were using; from this guide that is the guide itself, so there is no Try It.
    var tryable = true
    var id: String { query }

    static let all = [
        WelcomeExample(symbol: "app", title: "Open an app or a file", query: "safari"),
        WelcomeExample(symbol: "plus.forwardslash.minus", title: "Do sums and convert units", query: "10 km in mi"),
        WelcomeExample(symbol: "rectangle.lefthalf.filled", title: "Move the window you were using", query: "left half", tryable: false),
        WelcomeExample(symbol: "doc.on.clipboard", title: "Copy recent text again", query: "clip"),
        WelcomeExample(symbol: "timer", title: "Start a timer", query: "5m tea"),
        WelcomeExample(symbol: "calendar", title: "See your day", query: "my day"),
    ]
}

struct WelcomeTourPage: View {
    let tryQuery: (String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeading(title: "How it works", text: "Type what you want and press Return. ⌘K shows more actions for a row. Escape closes the launcher.")
            Form {
                Section {
                    ForEach(WelcomeExample.all) { example in
                        HStack(spacing: 10) {
                            Image(systemName: example.symbol).frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(example.title)
                                Text(example.query).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if example.tryable {
                                Button("Try It") { tryQuery(example.query) }.controlSize(.small)
                            } else {
                                Text("Try from another app").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Type / to see every function. Help › Welcome Guide opens this guide again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

struct WelcomeAIPage: View {
    @ObservedObject var preferences: Preferences
    let openSettings: (SettingsWindow.Tab) -> Void
    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeading(title: "AI helpers (optional)", text: "Both are off until you turn them on. Search, sums, windows, and voice run on this Mac.")
            Form {
                Section {
                    Text("Understands plain requests, such as “move this to the right half”. It only picks from the app’s own actions, and code checks every value.")
                        .font(.callout)
                } header: { Text("Jev · " + (preferences.jevEnabled ? "On" : "Off")) }
                Section {
                    Text("Answers questions and writes text. It never runs actions. You choose what it may read, such as selected text or mail.")
                        .font(.callout)
                } header: { Text("Luna · " + (preferences.lunaEnabled ? "On" : "Off")) }
                Section {
                    Text("Both use your own key. Clipboard history and audio are never sent, and no file paths are added to what you type. Each request is logged without its text.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Set Up in Settings › AI…") { openSettings(.ai) }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

struct WelcomeFinishPage: View {
    @ObservedObject var preferences: Preferences
    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeading(title: "You are ready", text: "\(AppIdentity.name) lives in the menu bar. If the menu bar is full, the icon can hide behind the notch; your shortcut still works.")
            Form {
                Section("Startup and updates") {
                    LoginItemRows(preferences: preferences)
                    Toggle("Check for updates automatically", isOn: $preferences.checksForUpdates)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}
