import AppKit
import LauncherCore
import SwiftUI

/// Settings › General › Clipboard.
struct ClipboardSettingsSections: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var history: ClipboardHistory
    @State private var confirmingClear = false

    private var settings: Binding<ClipboardSettings> { $preferences.clipboardSettings }
    private var on: Bool { preferences.clipboardSettings.enabled }

    var body: some View {
        Group {
            Section {
                Toggle("Keep clipboard history", isOn: settings.enabled)
                Toggle("Keep history after restart", isOn: settings.persist).disabled(!on)
                Picker("Keep entries for", selection: settings.keepDays) {
                    ForEach(ClipboardSettings.keepDayChoices, id: \.self) { days in Text(Self.daysTitle(days)).tag(days) }
                }
                .disabled(!on)
                Picker("Maximum unpinned entries", selection: settings.maxItems) {
                    ForEach(ClipboardSettings.maxItemChoices, id: \.self) { Text($0.formatted()).tag($0) }
                }
                .disabled(!on)
                Picker("Storage limit", selection: settings.maxBytes) {
                    ForEach(ClipboardSettings.maxByteChoices, id: \.self) { Text(ClipStyle.bytes($0)).tag($0) }
                }
                .disabled(!on)
                LabeledContent("In use") {
                    Text("\(history.entries.count.formatted()) entries · \(ClipStyle.bytes(history.storageBytes))").monospacedDigit()
                }
            } header: { Text("History") } footer: {
                Text("Type “clip” or press Hyper-V to open it. Pinned entries are kept even when limits are reached. Turning history off deletes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What to record") {
                Toggle("Text", isOn: settings.recordText)
                Toggle("Rich text formatting", isOn: settings.recordRichText).disabled(!preferences.clipboardSettings.recordText)
                Toggle("Images", isOn: settings.recordImages)
                Toggle("Files and media", isOn: settings.recordFiles)
                Toggle("Find text in images", isOn: settings.ocr)
                InfoCaption("Text in images is found on this Mac.",
                            detail: "Jevcast uses Apple’s Vision framework at low priority. The text is kept with the entry so search finds it, and Copy Text from Image copies it.")
            }
            .disabled(!on)
            Section {
                ForEach(preferences.clipboardSettings.ignoredApps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        if let icon = ClipAppIcons.icon(bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 16, height: 16).foregroundStyle(.secondary)
                        }
                        Text(Self.appName(bundleID)).lineLimit(1)
                        Text(bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        RemoveButton(label: "Stop ignoring \(Self.appName(bundleID))") {
                            preferences.clipboardSettings.ignoredApps.removeAll { $0 == bundleID }
                        }
                    }
                }
                HStack {
                    AddButton(title: "Add app…", action: addApp)
                    Spacer()
                    if Set(preferences.clipboardSettings.ignoredApps) != Set(ClipboardSettings.defaultIgnoredApps) {
                        Button("Restore Defaults") {
                            preferences.clipboardSettings.ignoredApps = Array(Set(preferences.clipboardSettings.ignoredApps + ClipboardSettings.defaultIgnoredApps)).sorted()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: { Text("Ignored apps") } footer: {
                Text("Copies made while these apps are in front are never recorded.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Label {
                    Text("Clipboard history stays on this Mac and is never sent anywhere. Passwords and other items that apps mark as concealed or temporary are skipped.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "lock.shield").foregroundStyle(.green) }
            }
            Section("Data") {
                ClipboardStorageWarning(history: history)
                HStack {
                    Button("Show Folder in Finder") {
                        let folder = ClipboardStore.defaultFolder
                        if FileManager.default.fileExists(atPath: folder.path) { Frontmost.reveal([folder]) }
                    }
                    .disabled(!preferences.clipboardSettings.persist || !FileManager.default.fileExists(atPath: ClipboardStore.defaultFolder.path))
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                        .disabled(history.entries.isEmpty && !history.canUndoDelete)
                }
                .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
                    Button("Clear History, Keep Pins", role: .destructive) { history.clear(includingPins: false) }
                    Button("Clear Everything, Including Pins", role: .destructive) { history.clear(includingPins: true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone.")
                }
            }
        }
    }

    static func daysTitle(_ days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    static func appName(_ bundleID: String) -> String {
        let known = [
            "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7", "com.bitwarden.desktop": "Bitwarden",
            "com.apple.keychainaccess": "Keychain Access", "com.apple.Passwords": "Passwords", "com.lastpass.LastPass": "LastPass",
            "com.dashlane.dashlanephonefinal": "Dashlane", "com.dashlane.Dashlane": "Dashlane"
        ]
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return known[bundleID] ?? bundleID
    }

    private func addApp() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        let ids = picker.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        preferences.clipboardSettings.ignoredApps = Array(Set(preferences.clipboardSettings.ignoredApps + ids)).sorted()
    }
}
