import SwiftUI
import LauncherCore

/// Settings › Mail › Accounts: where mail comes from, and the accounts Jevcast syncs itself.
struct MailAccountsSection: View {
    @ObservedObject private var center = NativeMailCenter.shared
    @State private var adding = false
    @State private var passwordFor: NativeMailAccount?
    @State private var removing: NativeMailAccount?
    @State private var signatureFor: NativeMailAccount?
    @State private var foldersFor: NativeMailAccount?
    @State private var reconnecting: String?

    var body: some View {
        Section {
            Picker("Read mail from", selection: Binding(get: { center.backend }, set: { center.setBackend($0) })) {
                ForEach(MailBackend.allCases) { Text($0.title).tag($0) }
            }
            InfoCaption(center.backend == .appleMail ? "Jevcast reads Apple Mail and makes changes through it." : "Jevcast syncs these accounts itself. Apple Mail is not used.",
                        detail: center.backend == .appleMail
                            ? "Apple Mail must run for new mail to arrive, and Jevcast needs Full Disk Access to read it."
                            : "Jevcast connects to each account's own IMAP and SMTP servers over TLS. Mail is kept in ~/Library/Application Support/Jevcast/Mail. Passwords are kept in the Keychain.")
            ForEach(center.accounts) { account in
                MailAccountRow(account: account, state: center.states[account.id], notice: center.notices[account.id],
                               active: center.backend == .jevcast,
                               password: { if account.authentication == .oauth { reconnect(account) } else { passwordFor = account } },
                               signature: { signatureFor = account }, folders: { foldersFor = account }, remove: { removing = account }, dismissNotice: { center.clearNotice(account.id) })
            }
            HStack {
                Button("Add Account…") { adding = true }
                Spacer()
                if center.backend == .jevcast, !center.accounts.isEmpty { Button("Check Now") { center.syncNow() } }
            }
            if let problem = center.problem { Text(problem).font(.caption).foregroundStyle(.red) }
        } header: { Text("Accounts") }
        .sheet(isPresented: $adding) { AddMailAccountSheet() }
        .sheet(item: $passwordFor) { MailPasswordSheet(account: $0) }
        .sheet(item: $signatureFor) { MailSignatureSheet(account: $0) }
        .sheet(item: $foldersFor) { MailFoldersSheet(account: $0) }
        .confirmationDialog("Remove \(removing?.email ?? "this account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove", role: .destructive) { Task { await center.remove(account) } }
        } message: { _ in
            Text("Its mail is deleted from this Mac. The mail stays on the server.")
        }
        MailOAuthSetupSection()
    }

    private func reconnect(_ account: NativeMailAccount) {
        guard reconnecting == nil else { return }
        reconnecting = account.id
        Task { @MainActor in
            defer { reconnecting = nil }
            do { try await center.reconnectOAuth(account) }
            catch { center.reportSetupError(error.localizedDescription) }
        }
    }
}

private struct MailAccountRow: View {
    let account: NativeMailAccount
    let state: MailAccountSync.State?
    let notice: String?
    let active: Bool
    let password: () -> Void
    let signature: () -> Void
    let folders: () -> Void
    let remove: () -> Void
    let dismissNotice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "envelope").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email)
                    Text(account.provider.title + " · " + status).font(.caption).foregroundStyle(failed ? .red : .secondary)
                }
                Spacer()
                Button("Signature…", action: signature).controlSize(.small)
                Button("Folders…", action: folders).controlSize(.small)
                Button(account.authentication == .oauth ? "Sign In Again…" : "Password…", action: password).controlSize(.small)
                Button("Remove…", role: .destructive, action: remove).controlSize(.small)
            }
            if let notice {
                HStack {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                    Button("OK", action: dismissNotice).buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var failed: Bool { if case .failed = state { return true }; return false }

    private var status: String {
        guard active else { return "Not used while Apple Mail is the mail source" }
        switch state {
        case nil, .starting?: return "Starting"
        case .syncing?: return "Syncing"
        case .ready(let date)?: return "Up to date, " + date.formatted(date: .omitted, time: .shortened)
        case .failed(let text, _)?: return text
        }
    }
}

/// Adds an account after the servers accept the sign-in.
struct AddMailAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = MailProvider.yahoo
    /// True once the service was picked by hand, so typing an address no longer changes it.
    @State private var providerPicked = false
    @State private var name = NSFullUserName()
    @State private var email = ""
    @State private var password = ""
    @State private var showsServers = false
    @State private var imap = MailProvider.yahoo.imap!
    @State private var smtp = MailProvider.yahoo.smtp!
    @State private var username = ""
    @State private var smtpUsername = ""
    @State private var savesSentCopy = true
    @State private var working = false
    @State private var error: String?
    @State private var usesOAuth = false
    @State private var signIn: Task<Void, Never>?

    init(demo: Bool = false) {
        if demo {
            _name = State(initialValue: "Alex Morgan"); _email = State(initialValue: "alex@example.com")
            _provider = State(initialValue: .gmail); _providerPicked = State(initialValue: true)
            _imap = State(initialValue: MailProvider.gmail.imap!); _smtp = State(initialValue: MailProvider.gmail.smtp!)
            _usesOAuth = State(initialValue: true); _savesSentCopy = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Mail Account").font(.title3.weight(.semibold))
            Form {
                Picker("Service", selection: Binding(get: { provider }, set: { choose($0, byHand: true) })) {
                    ForEach(MailProvider.allCases) { Text($0.title).tag($0) }
                }
                TextField("Name", text: $name)
                TextField("Email address", text: $email)
                    .textContentType(.emailAddress)
                    .onChange(of: email) { _, new in if !providerPicked { choose(MailProvider.guess(for: new), byHand: false) } }
                if provider == .gmail {
                    Picker("Sign-in method", selection: $usesOAuth) {
                        Text("Google Sign-In").tag(true); Text("App Password").tag(false)
                    }
                }
                if oauthProvider == nil { SecureField(provider == .other ? "Password" : "App password", text: $password) }
                VStack(alignment: .leading, spacing: 4) {
                    if let oauthProvider {
                        Text("Sign in in your browser. Jevcast requests access to this account's incoming and outgoing mail.").font(.caption).foregroundStyle(.secondary)
                        if (try? MailOAuthSetup.client(oauthProvider)) == nil {
                            Text("First save the " + oauthProvider.title + " OAuth client ID below Accounts in Settings › Mail.").font(.caption).foregroundStyle(.orange)
                            Link("Open " + oauthProvider.title + " App Setup", destination: oauthProvider.setupURL).font(.caption)
                        }
                    } else {
                        Text(provider.appPasswordHelp).font(.caption).foregroundStyle(.secondary)
                        if let url = provider.appPasswordURL { Link("Make an app password", destination: url).font(.caption) }
                    }
                }
                DisclosureGroup("Servers", isExpanded: Binding(get: { showsServers || provider == .other }, set: { showsServers = $0 })) {
                    ServerFields(title: "Incoming (IMAP)", server: $imap)
                    ServerFields(title: "Outgoing (SMTP)", server: $smtp)
                    TextField("IMAP user name", text: $username, prompt: Text(provider.imapUsername(for: email)))
                    TextField("SMTP user name", text: $smtpUsername, prompt: Text(email))
                    Toggle("Save a copy in Sent", isOn: $savesSentCopy)
                    Text("Turn this off when your server saves sent mail itself.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { signIn?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Sign In") { submit() }.keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { signIn?.cancel() }
    }

    private var oauthProvider: MailOAuthProvider? {
        provider == .outlook ? .microsoft : (provider == .gmail && usesOAuth ? .google : nil)
    }

    private var canSubmit: Bool {
        !working && (oauthProvider.map { (try? MailOAuthSetup.client($0)) != nil } ?? !password.isEmpty)
            && (try? MailActions.addresses(email))?.count == 1
            && (try? imap.validated()) != nil && (try? smtp.validated()) != nil
    }

    private func choose(_ new: MailProvider, byHand: Bool) {
        if byHand { providerPicked = true }
        guard new != provider || byHand else { return }
        provider = new
        username = ""; smtpUsername = ""
        usesOAuth = new == .gmail || new == .outlook
        savesSentCopy = !new.serverSavesSent
        if let preset = new.imap { imap = preset }
        if let preset = new.smtp { smtp = preset }
    }

    private func submit() {
        let address = (try? MailActions.addresses(email).first) ?? email.trimmingCharacters(in: .whitespaces)
        var account = NativeMailAccount(provider: provider, name: name.trimmingCharacters(in: .whitespaces), email: address,
                                        imap: imap, smtp: smtp)
        let typed = username.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { account.imapUsername = typed }
        if !smtpUsername.trimmingCharacters(in: .whitespaces).isEmpty { account.smtpUsername = smtpUsername.trimmingCharacters(in: .whitespaces) }
        account.savesSentCopy = savesSentCopy
        working = true
        error = nil
        account.authentication = oauthProvider == nil ? .password : .oauth
        signIn = Task { @MainActor in
            defer { working = false }
            do {
                if oauthProvider != nil { try await NativeMailCenter.shared.addOAuth(account) }
                else { try await NativeMailCenter.shared.add(account, password: password) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct ServerFields: View {
    let title: String
    @Binding var server: MailServer
    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("Host", text: $server.host).frame(minWidth: 180)
                TextField("Port", value: $server.port, format: .number.grouping(.never)).frame(width: 60)
                Picker("", selection: $server.security) {
                    Text("TLS").tag(MailSecurity.tls)
                    Text("STARTTLS").tag(MailSecurity.startTLS)
                }
                .labelsHidden().frame(width: 110)
            }
        }
    }
}

/// Saves a new app password once the server accepts it.
struct MailPasswordSheet: View {
    let account: NativeMailAccount
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password for \(account.email)").font(.title3.weight(.semibold))
            SecureField(account.provider == .other ? "Password" : "App password", text: $password)
            Text(account.provider.appPasswordHelp).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(password.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        working = true
        error = nil
        Task { @MainActor in
            defer { working = false }
            do { try await NativeMailCenter.shared.updatePassword(account, password: password); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
