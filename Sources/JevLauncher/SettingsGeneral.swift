import SwiftUI
import ServiceManagement

struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var status: LauncherStatus
    let changed: () -> Void
    @State private var loginStatus: SMAppService.Status
    @State private var loginError = ""
    init(preferences: Preferences, status: LauncherStatus, changed: @escaping () -> Void) {
        self.preferences = preferences; self.status = status; self.changed = changed
        // Read now, not on appear, so the window measures the approval row when it is shown.
        _loginStatus = State(initialValue: preferences.loginStatus)
    }
    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("Open Jev Launcher", selection: $preferences.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                }
                if let message = status.hotkeyMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Free the shortcut in Spotlight or other launchers first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(get: { loginStatus == .enabled }, set: setLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve Jev Launcher in Login Items.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                    }
                }
                if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section("Clipboard") {
                Toggle("Keep clipboard history", isOn: $preferences.clipboardHistory)
                Text("Type “clip” to see the last 50 text items. Kept in memory only. Concealed and password-manager items are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Web") {
                Picker("Search the web with", selection: $preferences.webEngine) {
                    Text("Google").tag("Google"); Text("DuckDuckGo").tag("DuckDuckGo")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = preferences.loginStatus }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = preferences.loginStatus
        }
        .onChange(of: preferences.hotkey) { _, _ in changed() }
    }
    private func setLogin(_ enabled: Bool) {
        do { loginStatus = try preferences.setLogin(enabled); loginError = "" }
        catch { loginError = error.localizedDescription; loginStatus = preferences.loginStatus }
    }
}
