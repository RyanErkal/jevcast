import SwiftUI
import LauncherCore

/// The bottom of Mail's sidebar: the gear that opens Mail Settings (Rules, Offline & Storage,
/// Signatures, and the other tool pages), and one quiet line that says how current the mail is.
/// When an account needs attention, the line says so and opens that account's details.
struct MailSidebarFooter: View {
    @ObservedObject var page: MailPage
    @ObservedObject var mail: MailModel
    @ObservedObject var center: NativeMailCenter

    var body: some View {
        // Nothing to show (no settings pages and no status): no band at all.
        if page.features != nil || line(now: Date()) != nil {
            VStack(spacing: 0) {
                Divider()
                bar
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            if page.features != nil {
                Menu { MailSettingsMenuItems(page: page) } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Mail Settings")
                    .accessibilityLabel("Mail Settings")
            }
            // Read again every 30 seconds, so "Updated 2 min ago" stays true.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let line = line(now: context.date) { status(line) }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 32)
    }

    /// Jevcast's own accounts report their sync; for Apple Mail, Jevcast knows when it last asked.
    private func line(now: Date) -> MailSyncStatusLine? {
        guard center.backend == .jevcast else {
            return .appleMail(running: mail.mailRunning, checking: mail.checkingMail, lastCheck: mail.lastAppleMailCheck, now: now)
        }
        let accounts = center.accounts.map { account in
            let queue = center.offlineQueueStatus[account.id]
            return MailSyncStatusLine.Account(id: account.id, state: center.states[account.id], lastSync: center.lastSuccessfulSync[account.id],
                                              needsReview: (queue?.failed ?? 0) + (queue?.review ?? 0) > 0)
        }
        return .native(accounts, online: center.isOnline, checking: mail.checkingMail, now: now)
    }

    @ViewBuilder private func status(_ line: MailSyncStatusLine) -> some View {
        let label = HStack(spacing: 4) {
            switch line.tone {
            case .busy: ProgressView().controlSize(.mini)
            case .offline: Image(systemName: "wifi.slash")
            case .attention: Image(systemName: "exclamationmark.triangle.fill")
            case .quiet: EmptyView()
            }
            // The narrowest sidebar fits the longest line a little smaller rather than cut short.
            Text(line.text).lineLimit(1).minimumScaleFactor(0.85).truncationMode(.tail)
        }
        .help(line.text)
        .font(.system(size: 11))
        .foregroundStyle(line.tone == .attention ? Color.orange : Color.secondary)
        if let id = line.accountID {
            Button { page.accountDetailsID = id } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Show the account's connection")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }
}

/// The Mail Settings pages, for the sidebar's gear, the list's menu, and the actions menu.
struct MailSettingsMenuItems: View {
    let page: MailPage
    var body: some View {
        ForEach(MailTool.allCases) { tool in
            Button(tool.rawValue) { page.openTool(tool) }
        }
    }
}
