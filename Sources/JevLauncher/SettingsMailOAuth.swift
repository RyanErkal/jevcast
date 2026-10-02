import SwiftUI
import LauncherCore

struct MailOAuthSetupSection: View {
    @State private var google = UISnapshots.directory == nil ? UserDefaults.standard.string(forKey: MailOAuthSetup.key(.google)) ?? "" : ""
    @State private var microsoft = UISnapshots.directory == nil ? UserDefaults.standard.string(forKey: MailOAuthSetup.key(.microsoft)) ?? "" : ""
    @State private var secret = ""
    @State private var secretStatus: String?
    @State private var note: String?
    var body: some View {
        Section("Google and Microsoft Sign-In") {
            setup(.google, value: $google)
            SecureField("Google desktop client secret (optional)", text: $secret)
            Text("Leave this empty to keep the saved secret. Secrets and mail tokens stay in the Keychain.").font(.caption).foregroundStyle(.secondary)
            if let secretStatus { Text(secretStatus).font(.caption).foregroundStyle(.secondary) }
            setup(.microsoft, value: $microsoft)
            HStack {
                Button("Save Sign-In Setup") { save() }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Saving setup does not connect a mailbox. Add an account to start sign-in.").font(.caption).foregroundStyle(.secondary)
        }
        .task { await readSecretStatus() }
    }
    private func readSecretStatus() async {
        guard UISnapshots.directory == nil else { return }
        secretStatus = await Task.detached {
            do {
                let saved = try KeychainStore.read(account: MailOAuthSetup.googleSecretKey)?.isEmpty == false
                return saved ? "Google client secret is saved and readable." : "No Google client secret is saved."
            } catch { return "Google client secret cannot be read. Enter it again, then save setup." }
        }.value
    }
    private func setup(_ provider: MailOAuthProvider, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(provider.title + " OAuth client ID", text: value)
            Text(provider.instructions).font(.caption).foregroundStyle(.secondary)
            Link("Open " + provider.title + " App Setup", destination: provider.setupURL).font(.caption)
        }
    }
    private func save() {
        do {
            let googleClient = google.isEmpty ? nil : try MailOAuthClient(provider: .google, clientID: google)
            let microsoftClient = microsoft.isEmpty ? nil : try MailOAuthClient(provider: .microsoft, clientID: microsoft)
            if !secret.isEmpty { try KeychainStore.save(secret, account: MailOAuthSetup.googleSecretKey); secret = "" }
            if let googleClient { UserDefaults.standard.set(googleClient.clientID, forKey: MailOAuthSetup.key(.google)) }
            else { UserDefaults.standard.removeObject(forKey: MailOAuthSetup.key(.google)) }
            if let microsoftClient { UserDefaults.standard.set(microsoftClient.clientID, forKey: MailOAuthSetup.key(.microsoft)) }
            else { UserDefaults.standard.removeObject(forKey: MailOAuthSetup.key(.microsoft)) }
            note = "Saved."
            Task { await readSecretStatus() }
        } catch { note = error.localizedDescription }
    }
}

struct MailSignatureSheet: View {
    let account: NativeMailAccount
    @Environment(\.dismiss) private var dismiss
    @State private var signature: String
    @State private var error: String?
    init(account: NativeMailAccount) { self.account = account; _signature = State(initialValue: account.signature ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signature for " + account.email).font(.headline)
            TextEditor(text: $signature).frame(height: 120).border(Color.secondary.opacity(0.2))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    do { try NativeMailCenter.shared.updateSignature(account, signature: signature); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 460)
    }
}
