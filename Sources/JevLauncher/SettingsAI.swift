import SwiftUI

/// Settings › AI: Jev, AI writing, and what they cost, one part at a time.
struct AISettings: View {
    /// The raw value is the part's title and is stored under "settingsAIPart".
    enum Part: CaseIterable, RawRepresentable {
        case jev, writing, usage
        init?(rawValue: String) {
            switch rawValue {
            case "Jev": self = .jev
            // "Quill" is the stored name earlier versions wrote for Writing.
            case "Writing", "Quill": self = .writing
            case "Usage": self = .usage
            default: return nil
            }
        }
        var rawValue: String {
            switch self {
            case .jev: return "Jev"
            case .writing: return "Writing"
            case .usage: return "Usage"
            }
        }
    }
    @ObservedObject var preferences: Preferences
    let model: LauncherModel
    let resized: () -> Void
    @AppStorage("settingsAIPart") private var part: Part = .jev

    var body: some View {
        Form {
            Section { PaneSections(selection: $part) }
            switch part {
            case .jev: JevSettings(preferences: preferences, keys: model.keys, aiWritingKeys: model.aiWritingKeys)
            case .writing: AIWritingSettings(preferences: preferences, log: model.aiWritingLog, jevKeys: model.keys, aiWritingKeys: model.aiWritingKeys, tasks: model.scheduledBriefs)
            case .usage: UsageSettings(preferences: preferences, usage: UISnapshots.directory == nil ? .shared : .snapshot)
            }
        }
        .formStyle(.grouped)
        .onChange(of: part) { _, _ in resized() }
    }
}

/// Settings › Mail: accounts, reading options, the access Apple Mail needs, and sign-in setup.
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
            MailAccountsSection(openMail: openMail)
            Section {
                Picker("Layout", selection: $split) {
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
                Toggle("Load web images, fonts, and styles", isOn: $loadsImages)
            } header: { Text("Reading") } footer: {
                InfoCaption("Mail never runs scripts. Senders can see when web images load.",
                            detail: "HTML mail can load images, fonts, and style sheets from the web. The ⋯ menu above a message changes this too. In the launcher, Space shows the message across the full panel. Escape shows the list again.")
            }
            if native.backend == .appleMail {
                Section("Access") {
                    SourcePermissionRow(kind: .fullDiskAccess)
                    SourcePermissionRow(kind: .automation)
                    Text("Reading needs Full Disk Access. Delete, move, and send go through Apple Mail, which needs Automation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("AI writing reads mail") {
                    Text(preferences.aiWritingEnabled && preferences.aiWritingSendsMail ? "On" : "Off").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Change this in Settings › AI › Writing.").font(.caption).foregroundStyle(.secondary)
            }
            // Only Gmail and Outlook sign-in need this, so it stays below everything else.
            MailOAuthSetupSection()
        }
        .formStyle(.grouped)
    }
}
