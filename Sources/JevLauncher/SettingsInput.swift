import SwiftUI

/// Settings › Voice: the voice input section.
struct VoiceSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var speech: SpeechService

    /// Shown only for a real failure or while speech input is active.
    private var speechStatus: String? {
        if let error = speech.errorMessage { return error }
        return speech.isListening || speech.isStarting ? speech.status : nil
    }

    var body: some View {
        Section {
            Toggle("Listen when the launcher opens", isOn: $preferences.voiceEnabled)
            if let speechStatus {
                Text(speechStatus).font(.caption).foregroundStyle(speech.errorMessage == nil ? Color.secondary : Color.orange)
            }
        } header: { Text("Voice input") } footer: {
            Text("Speech is changed to text on this Mac. Audio is not saved.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Jev: the key and natural-language matching. Shown in Settings › AI.
struct JevSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var keys: JevKeyCache
    @ObservedObject var aiWritingKeys: JevKeyCache
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var testing = false
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// AI writing borrows an OpenRouter Jev key when it has none of its own.
    private var sharedWithAIWriting: Bool { keys.provider == .openRouter && !aiWritingKeys.hasKey }

    var body: some View {
        Group { sections }.task { await keys.load(); await aiWritingKeys.load() }
    }
    @ViewBuilder private var sections: some View {
        Section {
            keyRow
            if case .failed(let message) = keys.state {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if !keyMessage.isEmpty { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
            if !keys.hasKey {
                HStack(spacing: 12) {
                    Link("Get a TypeSafe key", destination: AppIdentity.typeSafe)
                    Link("Get an OpenRouter key", destination: URL(string: "https://openrouter.ai/keys")!)
                }
                .font(.caption)
            }
        } header: { Text("Key") } footer: {
            InfoCaption(sharedWithAIWriting ? "Used by Jev and AI writing." : "Optional. A TypeSafe or OpenRouter key.",
                        detail: "Jev, a model from TypeSafe, matches loose requests such as “make this window bigger”. Use a TypeSafe key, or an OpenRouter key (sk-or-…) to run Jev through OpenRouter. AI writing uses an OpenRouter Jev key when it has no key of its own.")
        }
        Section {
            // Without a key the toggle reads off, whatever the stored preference is.
            Toggle("Understand loose requests", isOn: Binding(
                get: { keys.hasKey && preferences.jevEnabled }, set: { preferences.jevEnabled = $0 }
            )).disabled(!keys.hasKey)
            Toggle("More accurate matching", isOn: $preferences.jevLayered).disabled(!keys.hasKey || !preferences.jevEnabled)
        } header: { Text("Matching") } footer: {
            if keys.hasKey {
                InfoCaption("Jev matches a request such as “make this window bigger” to an action.",
                            detail: "Jev reads each request after a short pause. It gets the typed or spoken text and candidate names, never file paths, command text, or audio. With more accurate matching, Jev also names the kind of request, such as “open an app” or “move a window”. When that disagrees with its first pick, it chooses again among every item of that kind. Most requests then cost two small calls at once; a disagreement adds a third.")
            } else {
                Text("Jev matches a request such as “make this window bigger” to an action. Add a key to turn this on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var keyRow: some View {
        switch keys.state {
        case .unknown:
            LabeledContent("Key") { Text("Checking Keychain…").foregroundStyle(.secondary) }
        case .present:
            LabeledContent("Key") {
                HStack(spacing: 8) {
                    Text(keys.provider.map { $0.name + " key in Keychain" } ?? "Stored in Keychain").foregroundStyle(.secondary)
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }.disabled(testing)
                    Button("Remove", action: remove)
                }
                .controlSize(.small)
            }
        case .missing, .failed:
            HStack(spacing: 8) {
                SecureField("Jev key", text: $key, prompt: Text("Paste a TypeSafe or OpenRouter key"))
                    .onSubmit(save)
                Button("Save", action: save).controlSize(.small).disabled(trimmedKey.isEmpty)
            }
        }
    }
    private func save() {
        guard !trimmedKey.isEmpty else { return }
        do { try keys.save(trimmedKey); key = ""; keyMessage = "" }
        catch { keyMessage = error.localizedDescription }
    }
    private func remove() {
        do { try keys.delete(); preferences.jevEnabled = false; keyMessage = "" }
        catch { keyMessage = error.localizedDescription }
    }
    private func test() async {
        guard case .present(let value) = keys.state else { return }
        testing = true; keyMessage = ""
        defer { testing = false }
        do { try await JevService(usage: .shared).validate(apiKey: value); keyMessage = "Key works." }
        catch { keyMessage = JevService.statusMessage(for: error) }
    }
}

enum VoicePermissions {
    /// First request goes through the system prompt; a denied state opens System Settings.
    @MainActor static func request(_ permission: Permission, speech: SpeechService) -> () -> Void {
        {
            if permission.isUndetermined { Task { await speech.requestPermissions() } } else { permission.openSystemSettings() }
        }
    }
}
