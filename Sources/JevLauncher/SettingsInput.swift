import SwiftUI
import AVFoundation
import Speech

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
                     ? "Local results come first. Jev gets the request text and candidate names, never file paths or audio."
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
            LabeledContent("TypeSafe") { Text("Checking Keychain…").foregroundStyle(.secondary) }
        case .present:
            LabeledContent("TypeSafe") {
                HStack(spacing: 8) {
                    Text("Stored in Keychain").foregroundStyle(.secondary)
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }.disabled(testing)
                    Button("Remove", action: remove)
                }
                .controlSize(.small)
            }
        case .missing, .failed:
            HStack(spacing: 8) {
                SecureField("TypeSafe", text: $key, prompt: Text("Paste key"))
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
        do { try await JevService().validate(apiKey: value); keyMessage = "Key works." }
        catch { keyMessage = JevService.statusMessage(for: error) }
    }
    /// First request goes through the system prompt; a denied state opens System Settings.
    private func request(_ permission: Permission) -> () -> Void {
        {
            let undetermined = permission == .microphone
                ? AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                : SFSpeechRecognizer.authorizationStatus() == .notDetermined
            if undetermined { Task { await speech.requestPermissions() } } else { permission.openSystemSettings() }
        }
    }
}
