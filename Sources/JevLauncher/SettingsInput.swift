import SwiftUI

/// Voice input and Jev natural-language matching.
struct InputSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var speech: SpeechService
    @ObservedObject private var keys = JevKeyCache.shared
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var testing = false

    /// Shown only for a real failure or while speech input is active.
    private var speechStatus: String? {
        if let error = speech.errorMessage { return error }
        return speech.isListening || speech.isStarting ? speech.status : nil
    }
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section("Voice input") {
                Toggle("Listen when the launcher opens", isOn: $preferences.voiceEnabled)
                Text("Uses on-device speech recognition. Audio is not saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                PermissionRow(permission: .microphone, request: request(.microphone))
                PermissionRow(permission: .speech, request: request(.speech))
                if let speechStatus {
                    Text(speechStatus).font(.caption).foregroundStyle(speech.errorMessage == nil ? Color.secondary : Color.orange)
                }
            }
            Section("API key") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Optional. Jev, a model from TypeSafe, can match loose requests such as “make this window bigger”. Use your own TypeSafe key, or an OpenRouter key (sk-or-…) to run Jev through OpenRouter.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Link("Get a TypeSafe key", destination: AppIdentity.typeSafe)
                        Link("Get an OpenRouter key", destination: URL(string: "https://openrouter.ai/keys")!)
                    }
                }
                .font(.caption)
                keyRow
                if case .failed(let message) = keys.state {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                if !keyMessage.isEmpty { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Natural language") {
                // Without a key the toggle reads off, whatever the stored preference is.
                Toggle("Use Jev for natural-language matching", isOn: Binding(
                    get: { keys.hasKey && preferences.jevEnabled }, set: { preferences.jevEnabled = $0 }
                )).disabled(!keys.hasKey)
                Text(keys.hasKey
                     ? "Jev reads each request after a short pause, typed or spoken. It gets the text and candidate names, never file paths, command text, or audio."
                     : "Add a key to turn this on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await keys.load() }
    }

    @ViewBuilder private var keyRow: some View {
        switch keys.state {
        case .unknown:
            LabeledContent("Jev key") { Text("Checking Keychain…").foregroundStyle(.secondary) }
        case .present:
            LabeledContent("Jev key") {
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
    private func request(_ permission: Permission) -> () -> Void {
        VoicePermissions.request(permission, speech: speech)
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
