import AVFoundation
import SwiftUI
import LauncherCore

/// Hold Right Command to dictate. Off by default; audio is never saved or sent.
struct DictationSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var dictation: DictationController
    let openLuna: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Dictation") {
                if DictationEngines.isSupported {
                    Toggle("Hold Right Command to dictate", isOn: $preferences.dictationEnabled)
                    Text("Hold Right Command, speak, then let go. The text goes into the app in front. A short tap, or a shortcut such as ⌘C, records nothing. Speech is transcribed on this Mac; audio is kept in memory only and never saved or sent.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let preparing = dictation.preparing { Text(preparing).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Dictation needs macOS 26 or later.").foregroundStyle(.secondary)
                }
            }
            Section("Luna clean-up") {
                LabeledContent("Luna") {
                    Text(preferences.lunaEnabled && preferences.lunaSendsDictation ? "Cleans transcripts" : "Off").foregroundStyle(.secondary)
                }
                Text("Jevcast removes “um” and “uh” on this Mac. Luna can also fix punctuation and self-corrections. Turn on “Dictation transcripts” in Settings › AI › Luna to send transcript text; audio is never sent.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Luna Settings", action: openLuna).controlSize(.small)
            }
            Section("History") {
                Picker("Keep transcripts", selection: $preferences.dictationRetention) {
                    ForEach(DictationRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Text only, stored on this Mac. Type “dictation history” in the launcher to paste one again.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete All Transcripts…", role: .destructive) { confirmDelete = true }
                    .controlSize(.small)
                    .confirmationDialog("Delete all dictation transcripts?", isPresented: $confirmDelete) {
                        Button("Delete All", role: .destructive) { dictation.deleteHistory() }
                    }
            }
            Section("Permissions") {
                PermissionRow(permission: .microphone, request: {
                    if Permission.microphone.isUndetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                    else { Permission.microphone.openSystemSettings() }
                })
                PermissionRow(permission: .accessibility)
                Text("Accessibility lets Jevcast see Right Command in other apps and paste the text. Without it, the text is left on the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
