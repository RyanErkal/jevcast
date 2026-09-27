import SwiftUI

/// Settings › Voice: voice input in the launcher, and hold-to-dictate where macOS supports it.
struct VoicePane: View {
    enum Part: String, CaseIterable {
        case voice = "Voice input", dictation = "Dictation"
        /// Dictation needs macOS 26, so its part is hidden on older systems.
        static var shown: [Part] { allCases.filter { $0 != .dictation || DictationEngines.isSupported } }
    }
    @ObservedObject var preferences: Preferences
    let speech: SpeechService
    let dictation: DictationController
    let openQuill: () -> Void
    let resized: () -> Void
    @AppStorage("settingsVoicePart") private var part: Part = .voice

    var body: some View {
        let parts = Part.shown
        let current = parts.contains(part) ? part : .voice
        Form {
            if parts.count > 1 { Section { PaneSections(selection: $part, parts: parts) } }
            switch current {
            case .voice: VoiceSettings(preferences: preferences, speech: speech)
            case .dictation: DictationSettings(preferences: preferences, dictation: dictation, openQuill: openQuill)
            }
        }
        .formStyle(.grouped)
        .onChange(of: part) { _, _ in resized() }
    }
}
