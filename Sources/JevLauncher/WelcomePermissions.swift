import AppKit
import SwiftUI

/// Every permission in one list. Nothing is asked until the user clicks.
/// Rows poll, because Accessibility is granted in System Settings with no callback.
struct WelcomePermissionsPage: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: LauncherModel
    @ObservedObject var speech: SpeechService
    @State private var asking = false
    @State private var promptable = WelcomePermissions.promptable()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeading(title: "Permissions", text: "Allow only what you want to use. Each feature also asks the first time you use it.")
            Form {
                if asking || !promptable.isEmpty {
                    Section {
                        Button(asking ? "Asking…" : "Allow Calendars, Reminders, and Contacts") { Task { await askPrompted() } }
                            .disabled(asking)
                    } footer: {
                        Text("macOS shows one prompt for each. Rows below that open System Settings need a switch turned on there.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Windows") {
                    PermissionRow(permission: .accessibility) { model.windows.requestPermission() }
                }
                Section("Your data") {
                    SourcePermissionRow(kind: .calendars)
                    SourcePermissionRow(kind: .reminders)
                    SourcePermissionRow(kind: .contacts)
                    SourcePermissionRow(kind: .fullDiskAccess)
                    SourcePermissionRow(kind: .automation)
                }
                Section {
                    Toggle("Listen when the launcher opens", isOn: voice)
                    if preferences.voiceEnabled {
                        PermissionRow(permission: .microphone, request: VoicePermissions.request(.microphone, speech: speech))
                        PermissionRow(permission: .speech, request: VoicePermissions.request(.speech, speech: speech))
                    }
                } header: { Text("Voice") } footer: {
                    Text("Speech becomes text on this Mac. Audio is not saved.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
        .onReceive(refresh) { _ in promptable = WelcomePermissions.promptable() }
    }

    /// Only undetermined permissions show a macOS prompt; a refused one would open System Settings instead, so it is left alone.
    private func askPrompted() async {
        asking = true
        defer { asking = false; promptable = WelcomePermissions.promptable() }
        for kind in WelcomePermissions.promptable() { await Permissions.request(kind.access) }
    }

    /// Turning voice on asks for both permissions the first time; after a denial, the rows open System Settings.
    private var voice: Binding<Bool> {
        Binding(get: { preferences.voiceEnabled }, set: { enabled in
            preferences.voiceEnabled = enabled
            if enabled && (Permission.microphone.isUndetermined || Permission.speech.isUndetermined) {
                Task { await speech.requestPermissions() }
            }
        })
    }
}

@MainActor
enum WelcomePermissions {
    /// The source permissions that can still show a macOS prompt.
    static func promptable(isUndetermined: ((SourcePermissionRowKind) -> Bool)? = nil) -> [SourcePermissionRowKind] {
        [.calendars, .reminders, .contacts].filter { isUndetermined?($0) ?? $0.isUndetermined }
    }
}
