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
    @AppStorage(MailReading.splitKey) private var split = MailReading.Split.balanced.rawValue
    @AppStorage(MailReading.zoomKey) private var zoom = 1.0
    @AppStorage(MailReading.fitKey) private var fitsWidth = true
    @AppStorage(MailReading.markReadKey) private var markRead = MailReading.MarkRead.oneSecond.rawValue
    @AppStorage(MailReading.plainKey) private var prefersPlain = false

    @ObservedObject private var native = NativeMailCenter.shared

    var body: some View {
        Form {
            MailAccountsSection()
            Section {
                Toggle("Load web images, fonts, and styles", isOn: $loadsImages)
                InfoCaption("Mail never runs scripts.",
                            detail: "HTML mail can load images, fonts, and style sheets from the web. Senders can see when those load. The ⋯ menu in the mail window changes this too.")
                HStack { Spacer(); Button("Open Mail") { openMail() }.controlSize(.small) }
            } header: { Text("Inbox") }
            Section {
                Picker("List and message", selection: $split) {
                    ForEach(MailReading.Split.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $zoom, in: MailReading.zoomRange, step: 0.05).frame(width: 180)
                        Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Fit wide emails to the width", isOn: $fitsWidth)
                Picker("Mark as read", selection: $markRead) {
                    ForEach(MailReading.MarkRead.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Prefer plain text", isOn: $prefersPlain)
                Text("In the launcher, Space shows the message across the full panel. Escape shows the list again. ⌘O opens the Mail window.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Reading") }
            if native.backend == .appleMail {
                Section("Access") {
                    SourcePermissionRow(kind: .fullDiskAccess)
                    SourcePermissionRow(kind: .automation)
                    Text("Reading needs Full Disk Access. Delete, move, and send go through Apple Mail, which needs Automation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Quill") {
                LabeledContent("Quill reads mail") {
                    Text(preferences.quillEnabled && preferences.quillSendsMail ? "On" : "Off").foregroundStyle(.secondary)
                }
                Text("Change this in Settings › AI › Quill.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
