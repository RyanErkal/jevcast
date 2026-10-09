import SwiftUI
import LauncherCore

struct MailAccountConnectionStatus {
    let state: MailAccountSync.State?

    var title: String {
        switch state {
        case .starting: return "Connecting"
        case .syncing: return "Syncing…"
        case .ready: return "Connected"
        case .failed(_, let signIn): return signIn ? "Sign in required" : "Connection interrupted"
        case nil: return "Not checked yet"
        }
    }

    var needsSignIn: Bool {
        if case .failed(_, signIn: true) = state { return true }
        return false
    }

    var detail: String {
        switch state {
        case .failed(let reason, let signIn):
            return reason + (signIn ? " Sync is paused until you reconnect." : " Sync will retry automatically.")
        case .starting, .syncing: return "Jevcast is checking this account for mail."
        case .ready: return "Incoming mail is connected. Older mail continues to load as you browse."
        case nil: return "Jevcast has not reported a connection check for this account yet."
        }
    }
}

/// Account recovery replaces the reader inside the launcher. It never opens a mail window.
struct MailAccountConnectionView: View {
    @ObservedObject var center: NativeMailCenter
    @ObservedObject var recovery: MailAccountRecovery
    let accountID: String
    let back: () -> Void
    @State private var password = ""

    private var account: NativeMailAccount? { center.accounts.first { $0.id == accountID } }
    private var status: MailAccountConnectionStatus { .init(state: center.states[accountID]) }
    private var working: Bool { recovery.working.contains(accountID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: back) { Label("Back to mail", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                if let account {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account connection").font(.title2.weight(.semibold))
                        Text(account.email).font(.headline).textSelection(.enabled)
                        Text(account.provider.title).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label(status.title, systemImage: status.needsSignIn ? "person.crop.circle.badge.exclamationmark" : "envelope")
                            .font(.headline)
                        Text(status.detail).fixedSize(horizontal: false, vertical: true)
                        if let date = center.lastSuccessfulSync[accountID] {
                            Text("Last successful sync: " + date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No successful sync recorded yet.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Previously downloaded mail stays available. Counts can be out of date while disconnected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    if working {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(account.authentication == .oauth ? "Finish sign-in in your browser." : "Checking incoming and outgoing mail…")
                        }
                        Text("You can return to mail. The connection check will continue.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Cancel sign-in") { recovery.cancel(accountID) }
                    } else {
                        if account.authentication == .oauth {
                            Text("Reconnect with " + account.provider.title + ". Your browser will open for sign-in.")
                                .font(.callout)
                        } else {
                            SecureField(account.provider == .other ? "Mail password" : "App password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { reconnect(account) }
                            Text(account.provider.appPasswordHelp).font(.caption).foregroundStyle(.secondary)
                            if let url = account.provider.appPasswordURL {
                                Link("Create an app password", destination: url).font(.caption)
                            }
                        }
                        HStack(spacing: 12) {
                            Button("Reconnect") { reconnect(account) }
                                .buttonStyle(.borderedProminent)
                                .disabled(account.authentication != .oauth && password.isEmpty)
                            if !status.needsSignIn {
                                Button("Retry sync") { center.retrySync(accountID) }
                            }
                        }
                        Text("Reconnect checks both incoming and outgoing sign-in. It does not send a message.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = recovery.errors[accountID] {
                        Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Provider and server settings are in Settings › Mail.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This account was removed.").font(.headline)
                }
                Spacer(minLength: 0)
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { password = "" }
    }

    private func reconnect(_ account: NativeMailAccount) {
        guard account.authentication == .oauth || !password.isEmpty else { return }
        recovery.start(account, password: account.authentication == .oauth ? nil : password)
        password = ""
    }
}
