import SwiftUI
import LauncherCore

enum MailTool: String, CaseIterable, Identifiable {
    case offline = "Offline & Storage", rules = "Rules", smart = "Smart Mailboxes & Senders"
    case notifications = "Notifications", scheduled = "Scheduled", snoozed = "Snoozed"
    case archive = "Import & Export", aliases = "Aliases & Signatures"
    var id: String { rawValue }
}

/// Management uses the existing launcher surface and returns to the same message or draft.
struct MailToolsView: View {
    let tool: MailTool
    @ObservedObject var page: MailPage
    @ObservedObject var center: MailFeatureCenter
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { page.tool = nil } label: { Label("Mail", systemImage: "chevron.left") }
                Picker("Mail tools", selection: Binding(get: { tool }, set: { page.tool = $0 })) {
                    ForEach(MailTool.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(maxWidth: 270)
                Spacer()
                if center.refreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { center.refresh(full: true) }
            }.padding(10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let problem = center.problem { Text(problem).font(.caption).foregroundStyle(.orange).padding(8) }
        }
    }

    @ViewBuilder private var content: some View {
        switch tool {
        case .offline: MailOfflineSettingsView(center: page.accountCenter)
        case .rules:
            VStack(spacing: 0) {
                coverage
                MailRulesView(controller: center.rules)
            }
        case .smart:
            VStack(spacing: 0) {
                coverage
                MailSmartView(controller: center.smart)
            }
        case .notifications: MailNotificationSettingsView(center: center.notifications, accounts: page.accountCenter.accounts)
        case .scheduled:
            ScrollView { MailScheduleList(center: center.schedules, onReturnToDrafts: { page.mail?.restoreScheduled($0) }) }
        case .snoozed:
            ScrollView { MailSnoozeList(center: center.snoozes) { entry in center.openSnoozed(entry, page: page) } }
        case .archive:
            if let archive = try? center.archive() { MailArchiveView(store: archive) }
            else { ContentUnavailableView("Archive unavailable", systemImage: "exclamationmark.triangle", description: Text("The local archive could not be opened. Check its file permissions.")) }
        case .aliases: MailAliasSettingsView(accounts: page.accountCenter.accounts, defaults: center.settingsDefaults)
        }
    }

    private var coverage: some View {
        Text("Matches use downloaded mail. Recipient filters require downloaded message bodies.")
            .font(.caption).foregroundStyle(.secondary).padding(8)
    }
}

struct MailNotificationSettingsView: View {
    @ObservedObject var center: MailNotificationCenter
    let accounts: [NativeMailAccount]
    var body: some View {
        Form {
            Section("New mail on this Mac") {
                Text("A small mark appears beside the notch. Click it to open the mail notice. Old mail and backfills stay silent.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(accounts) { account in
                    Toggle(account.email, isOn: Binding(get: { center.settings.enabledAccounts.contains(account.id) },
                        set: { center.setAccount(account.id, enabled: $0) }))
                }
                Toggle("Hide sender and subject", isOn: Binding(get: { center.settings.privatePreviews }, set: center.setPrivatePreviews))
            }
            Section("Quiet hours") {
                Toggle("Use quiet hours", isOn: Binding(get: { center.settings.quietStartMinute != nil }, set: {
                    center.setQuietHours(startMinute: $0 ? 1320 : nil, endMinute: $0 ? 480 : nil)
                }))
                if center.settings.quietStartMinute != nil {
                    DatePicker("From", selection: quietTime(start: true), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: quietTime(start: false), displayedComponents: .hourAndMinute)
                }
            }
            if let error = center.persistenceError ?? center.settingsError { Text(error).foregroundStyle(.orange) }
        }.formStyle(.grouped)
    }
    private func quietTime(start: Bool) -> Binding<Date> {
        Binding(get: {
            let minutes = (start ? center.settings.quietStartMinute : center.settings.quietEndMinute) ?? 0
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            center.setQuietHours(startMinute: start ? minutes : center.settings.quietStartMinute,
                                 endMinute: start ? center.settings.quietEndMinute : minutes)
        })
    }
}
