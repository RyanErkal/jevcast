import SwiftUI

/// Settings › General: the shortcut, permissions, and network in General; clipboard history in Clipboard.
struct GeneralSettings: View {
    enum Part: String, CaseIterable { case general = "General", clipboard = "Clipboard" }
    @ObservedObject var preferences: Preferences
    @ObservedObject var status: LauncherStatus
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var speech: SpeechService
    let windows: WindowManager
    @ObservedObject var keys: JevKeyCache
    let history: ClipboardHistory
    let changed: () -> Void
    let resized: () -> Void
    @AppStorage("settingsGeneralPart") private var part: Part = .general
    var body: some View {
        Form {
            Section { PaneSections(selection: $part) }
            switch part {
            case .general: generalSections
            case .clipboard: ClipboardSettingsSections(preferences: preferences, history: history)
            }
        }
        .formStyle(.grouped)
        .onChange(of: part) { _, _ in resized() }
        .onChange(of: preferences.hotkey) { _, _ in changed() }
        .task { await keys.load() }
    }

    @ViewBuilder private var generalSections: some View {
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
                LoginItemRows(preferences: preferences)
            }
            Section("Launcher") {
                Picker("Search the web with", selection: $preferences.webEngine) {
                    Text("Google").tag("Google"); Text("DuckDuckGo").tag("DuckDuckGo")
                }
                LabeledContent("Clipboard history") {
                    Button(preferences.clipboardHistory ? "On · Settings…" : "Off · Settings…") { part = .clipboard }
                        .buttonStyle(.link)
                }
            }
            Section {
                PermissionRow(permission: .accessibility) { windows.requestPermission() }
                PermissionRow(permission: .microphone, request: VoicePermissions.request(.microphone, speech: speech))
                PermissionRow(permission: .speech, request: VoicePermissions.request(.speech, speech: speech))
                PermissionRow(permission: .inputMonitoring, request: Permission.requestInputMonitoring)
                ForEach(SourcePermissionRowKind.allCases) { SourcePermissionRow(kind: $0) }
            } header: { Text("Permissions") } footer: {
                Text("Each feature asks when you first use it. macOS does not tell apps about Full Disk Access or Automation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for updates once a day", isOn: $preferences.checksForUpdates)
                Toggle("Jev natural-language matching", isOn: Binding(
                    get: { keys.hasKey && preferences.jevEnabled }, set: { preferences.jevEnabled = $0 }
                )).disabled(!keys.hasKey)
                Toggle("Quill answers and writing", isOn: $preferences.quillEnabled)
                HStack {
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let release = updates.available {
                        Button("Download \(release.version)") { Frontmost.open(release.page) }.controlSize(.small)
                    } else {
                        Button("Check Now") { updates.checkAndReport() }.controlSize(.small).disabled(updates.state == .checking)
                    }
                }
            } header: { Text("Network") } footer: {
                InfoCaption("These, and web images in mail, are the only network use.",
                            detail: "HTML mail loads web images, fonts, and styles unless you turn that off in Settings › Mail. The update check asks GitHub for the newest version and sends nothing else. Jev gets request text and candidate names. Quill gets only what Settings › AI › Quill allows. File paths, clipboard history, and audio are never sent.")
            }
            if !preferences.cleanupIgnored.isEmpty {
                Section("Ignored by Clean Up") {
                    ForEach(preferences.cleanupIgnored, id: \.self) { key in
                        HStack {
                            Text(key)
                            Spacer()
                            Button("Offer Again") { preferences.cleanupIgnored.removeAll { $0 == key } }.controlSize(.small)
                        }
                    }
                }
            }
    }
    private var updateStatus: String {
        switch updates.state {
        case .available(let release): return "Version \(release.version) is available. You have \(AppIdentity.version)."
        case .checking: return "Checking…"
        default: return "Version \(AppIdentity.version)."
        }
    }
}
