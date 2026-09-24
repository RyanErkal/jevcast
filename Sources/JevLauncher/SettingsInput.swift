import SwiftUI

/// Voice input and its permissions.
struct VoiceSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var speech: SpeechService

    /// Shown only for a real failure or while speech input is active.
    private var speechStatus: String? {
        if let error = speech.errorMessage { return error }
        return speech.isListening || speech.isStarting ? speech.status : nil
    }

    var body: some View {
        Form {
            Section("Voice input") {
                Toggle("Listen when the launcher opens", isOn: $preferences.voiceEnabled)
                Text("Uses on-device speech recognition. Audio is not saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                PermissionRow(permission: .microphone, request: VoicePermissions.request(.microphone, speech: speech))
                PermissionRow(permission: .speech, request: VoicePermissions.request(.speech, speech: speech))
                if let speechStatus {
                    Text(speechStatus).font(.caption).foregroundStyle(speech.errorMessage == nil ? Color.secondary : Color.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Jev: the key and natural-language matching. Shown in Settings › AI.
struct JevSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var keys: JevKeyCache
    @ObservedObject var lunaKeys: JevKeyCache
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var testing = false
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Luna borrows an OpenRouter Jev key when it has none of its own.
    private var sharedWithLuna: Bool { keys.provider == .openRouter && !lunaKeys.hasKey }

    var body: some View {
        Group { sections }.task { await keys.load(); await lunaKeys.load() }
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
        } header: { Text("Jev") } footer: {
            InfoCaption(sharedWithLuna ? "Used by Jev and Luna." : "Optional. A TypeSafe or OpenRouter key.",
                        detail: "Jev, a model from TypeSafe, matches loose requests such as “make this window bigger”. Use a TypeSafe key, or an OpenRouter key (sk-or-…) to run Jev through OpenRouter. Luna uses an OpenRouter Jev key when it has no key of its own.")
        }
        Section("Natural language") {
            // Without a key the toggle reads off, whatever the stored preference is.
            Toggle("Use Jev for natural-language matching", isOn: Binding(
                get: { keys.hasKey && preferences.jevEnabled }, set: { preferences.jevEnabled = $0 }
            )).disabled(!keys.hasKey)
            if keys.hasKey {
                InfoCaption("Reads each request after a short pause.",
                            detail: "Jev gets the typed or spoken text and candidate names, never file paths, command text, or audio.")
            } else {
                Text("Add a key to turn this on.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Check the kind of request first", isOn: $preferences.jevLayered).disabled(!keys.hasKey || !preferences.jevEnabled)
            InfoCaption("More accurate. Usually two small calls.",
                        detail: "Jev also names the kind of request, such as “open an app” or “move a window”. When that disagrees with its first pick, it chooses again among every item of that kind. Most requests cost two small calls at once; a disagreement adds a third.")
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
