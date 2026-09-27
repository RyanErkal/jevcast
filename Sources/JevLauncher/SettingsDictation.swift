import AVFoundation
import SwiftUI
import LauncherCore

/// Hold Right Command to dictate. Off by default; audio is never saved or sent.
struct DictationSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var dictation: DictationController
    let openQuill: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Dictation") {
                if DictationEngines.isSupported {
                    Toggle("Hold Right Command to dictate", isOn: $preferences.dictationEnabled)
                    InfoCaption("Speak, then let go. The text goes into the app in front.",
                                detail: "A short tap, or a shortcut such as ⌘C, records nothing. Speech is changed to text on this Mac. Audio stays in memory only. It is never saved or sent.")
                    if let preparing = dictation.preparing { Text(preparing).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Dictation needs macOS 26 or later.").foregroundStyle(.secondary)
                }
            }
            Section("Clean-up") {
                LabeledContent("Quill clean-up") {
                    HStack {
                        Text(preferences.quillEnabled && preferences.quillSendsDictation ? "On" : "Off").foregroundStyle(.secondary)
                        Button("Quill Settings…", action: openQuill).controlSize(.small)
                    }
                }
                InfoCaption("“Um” and “uh” are always removed on this Mac.",
                            detail: "Quill can also fix punctuation and corrections you speak. To send transcript text, turn on “Dictation transcripts” in Settings › AI › Quill. Audio is never sent.")
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
                Text("Accessibility lets \(AppIdentity.name) see Right Command and paste the text. Without it, the text stays on the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
