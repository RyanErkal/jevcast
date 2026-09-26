import SwiftUI

/// Settings › AI: Jev, Quill, and what they cost, one part at a time.
struct AISettings: View {
    enum Part: String, CaseIterable { case jev = "Jev", quill = "Quill", usage = "Usage" }
    @ObservedObject var preferences: Preferences
    let model: LauncherModel
    let resized: () -> Void
    @AppStorage("settingsAIPart") private var part: Part = .jev

    var body: some View {
        Form {
            Section { PaneSections(selection: $part) }
            switch part {
            case .jev: JevSettings(preferences: preferences, keys: model.keys, quillKeys: model.quillKeys)
            case .quill: QuillSettings(preferences: preferences, log: model.quillLog, jevKeys: model.keys, quillKeys: model.quillKeys, tasks: model.quillTasks)
            case .usage: UsageSettings(preferences: preferences, usage: JevUsageLog.shared)
            }
        }
        .formStyle(.grouped)
        .onChange(of: part) { _, _ in resized() }
    }
}

/// Settings › Mail: the inbox window's options and the access it needs.
struct MailSettings: View {
    @ObservedObject var preferences: Preferences
    let openMail: () -> Void
    @AppStorage("mailLoadsImages") private var loadsImages = true

    var body: some View {
        Form {
            Section {
                Toggle("Load web images, fonts, and styles", isOn: $loadsImages)
                InfoCaption("Mail never runs scripts.",
                            detail: "HTML mail can load images, fonts, and style sheets from the web. Senders can see when those load. The ⋯ menu in the mail window changes this too.")
                HStack { Spacer(); Button("Open Mail") { openMail() }.controlSize(.small) }
            } header: { Text("Inbox") }
            Section("Access") {
                SourcePermissionRow(kind: .fullDiskAccess)
                SourcePermissionRow(kind: .automation)
                Text("Reading needs Full Disk Access. Delete, move, and send go through Apple Mail, which needs Automation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quill") {
                Toggle("Quill may read messages for summaries and replies", isOn: $preferences.quillSendsMail)
                    .disabled(!preferences.quillEnabled)
                if !preferences.quillEnabled {
                    Text("Turn on Quill in Settings › AI first.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
