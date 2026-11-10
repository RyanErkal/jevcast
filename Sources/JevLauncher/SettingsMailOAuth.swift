import SwiftUI
import LauncherCore

struct MailOAuthSetupSection: View {
    @State private var google = UISnapshots.directory == nil ? UserDefaults.standard.string(forKey: MailOAuthSetup.key(.google)) ?? "" : ""
    @State private var microsoft = UISnapshots.directory == nil ? UserDefaults.standard.string(forKey: MailOAuthSetup.key(.microsoft)) ?? "" : ""
    @State private var secret = ""
    @State private var secretStatus: String?
    @State private var note: String?
    /// The setup steps stay closed until asked for. Most accounts never need them.
    @State private var expanded = false
    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign-in setup for Gmail and Outlook")
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? "Done" : "Set Up…") { expanded.toggle() }
            }
            if expanded {
                setup(.google, value: $google)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Google client secret (optional)").font(.system(size: 13, weight: .medium))
                    SecureField("", text: $secret, prompt: Text("Leave empty to keep the saved secret")).textFieldStyle(.roundedBorder).labelsHidden()
                    Text(secretStatus ?? "Secrets and mail tokens stay in the Keychain.").font(.caption).foregroundStyle(.secondary)
                }
                setup(.microsoft, value: $microsoft)
                HStack {
                    Button("Save Sign-In Setup") { save() }.buttonStyle(.borderedProminent)
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Saving setup does not connect a mailbox. Add an account to start sign-in.").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Google and Microsoft Sign-In") }
        .task { await readSecretStatus() }
    }
    /// "Google is set up. Microsoft is not set up." Yahoo, iCloud, and others need neither.
    private var summary: String {
        let state = { (value: String) in value.isEmpty ? "is not set up" : "is set up" }
        return "Google \(state(google)). Microsoft \(state(microsoft)). Other mail providers need no setup here."
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
            Text(provider.title + " client ID").font(.system(size: 13, weight: .medium))
            // A visible box: an empty field with no border looks like no field at all.
            TextField("", text: value, prompt: Text("Paste the client ID")).textFieldStyle(.roundedBorder).labelsHidden()
                .accessibilityLabel(provider.title + " OAuth client ID")
            Text(provider.instructions).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
