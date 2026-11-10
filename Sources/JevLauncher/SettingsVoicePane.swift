import SwiftUI

/// Settings › Voice: voice input in the launcher, then hold-to-dictate where macOS supports it.
struct VoicePane: View {
    @ObservedObject var preferences: Preferences
    let speech: SpeechService
    let dictation: DictationController
    let openAIWritingSettings: () -> Void
    let resized: () -> Void

    var body: some View {
        Form {
            VoiceSettings(preferences: preferences, speech: speech)
            if DictationEngines.isSupported {
                DictationSettings(preferences: preferences, dictation: dictation, openAIWritingSettings: openAIWritingSettings)
            }
            MissingPermissions(permissions, changed: resized)
        }
        .formStyle(.grouped)
    }

    private var permissions: [MissingPermissions.Item] {
        var items: [MissingPermissions.Item] = [
            .init(.microphone, request: VoicePermissions.request(.microphone, speech: speech)),
            .init(.speech, request: VoicePermissions.request(.speech, speech: speech))
        ]
        if DictationEngines.isSupported {
            items.append(.init(.accessibility, note: "Dictation needs Accessibility to see Right Command and paste the text. Without it, the text stays on the clipboard."))
        }
        return items
    }
}
