import SwiftUI
import LauncherCore

/// Settings › Voice: hold Right Command to dictate. Off by default; audio is never saved or sent.
struct DictationSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var dictation: DictationController
    let openAIWritingSettings: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Toggle("Hold Right Command to dictate", isOn: $preferences.dictationEnabled)
            if let preparing = dictation.preparing { Text(preparing).font(.caption).foregroundStyle(.secondary) }
            LabeledContent("AI clean-up") {
                HStack {
                    Text(preferences.aiWritingEnabled && preferences.aiWritingSendsDictation ? "On" : "Off").foregroundStyle(.secondary)
                    Button("Writing Settings…", action: openAIWritingSettings).controlSize(.small)
                }
            }
        } header: { Text("Dictation") } footer: {
            InfoCaption("Speak, then let go. The text goes into the app in front.",
                        detail: "A short tap, or a shortcut such as ⌘C, records nothing. Speech is changed to text on this Mac. Audio stays in memory only. It is never saved or sent. “Um” and “uh” are always removed on this Mac. AI clean-up also fixes punctuation and corrections you speak. To send transcript text, turn on “Dictation transcripts” in Settings › AI › Writing.")
        }
        Section {
            Picker("Keep transcripts", selection: $preferences.dictationRetention) {
                ForEach(DictationRetention.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Delete All Transcripts…", role: .destructive) { confirmDelete = true }
                .controlSize(.small)
                .confirmationDialog("Delete all dictation transcripts?", isPresented: $confirmDelete) {
                    Button("Delete All", role: .destructive) { dictation.deleteHistory() }
                }
        } footer: {
            Text("Text only, stored on this Mac. Type “dictation history” in the launcher to paste one again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
