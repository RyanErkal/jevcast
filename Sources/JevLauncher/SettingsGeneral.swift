import SwiftUI

struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var status: LauncherStatus
    @ObservedObject var updates: UpdateChecker
    let changed: () -> Void
    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("Open \(AppIdentity.name)", selection: $preferences.hotkey) {
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
                LoginItemRows(preferences: preferences)
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
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $preferences.checksForUpdates)
                HStack {
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let release = updates.available {
                        Button("Download \(release.version)") { Frontmost.open(release.page) }.controlSize(.small)
                    } else {
                        Button("Check Now") { updates.checkAndReport() }.controlSize(.small).disabled(updates.state == .checking)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.hotkey) { _, _ in changed() }
    }
    /// Says what the check sends, so the one network call is never a surprise.
    private var updateStatus: String {
        switch updates.state {
        case .available(let release): return "Version \(release.version) is available. You have \(AppIdentity.version)."
        case .checking: return "Checking…"
        default: return "Version \(AppIdentity.version). Once a day, the app asks GitHub for the newest version. It sends nothing else."
        }
    }
}
