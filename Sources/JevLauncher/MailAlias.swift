import Foundation
import SwiftUI
import LauncherCore

/// A provider-authorized alternate From identity. Authorization is an explicit local assertion,
/// never an unchecked From string. The account ID remains the credential and envelope owner.
struct MailAlias: Codable, Equatable, Hashable, Identifiable, Sendable {
    let accountID: String
    let address: String
    var name: String
    var signature: String
    var providerAuthorized: Bool

    var id: String { accountID + ":" + address.lowercased() }
    var title: String { name.isEmpty ? address : "\(name) <\(address)>" }

    func validated(accountAddress: String) -> Bool {
        guard providerAuthorized, !accountID.isEmpty, MailRecipientParser.isAddress(address),
              !name.contains(where: { $0.isNewline || $0 == "\u{0}" }),
              !signature.contains("\u{0}") else { return false }
        // An alias may be on another domain, but it must never replace the account credential.
        // The account address is passed separately to the mail transport.
        return !accountAddress.isEmpty && MailRecipientParser.isAddress(accountAddress)
    }
}

enum MailAliasStore {
    static let defaultsKey = "mail.providerAuthorizedAliases.v1"

    static func load(defaults: UserDefaults = .standard) -> [MailAlias] {
        guard let data = defaults.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([MailAlias].self, from: data) else { return [] }
        return values
    }

    private static func save(_ aliases: [MailAlias], defaults: UserDefaults = .standard) throws {
        var unique: [MailAlias] = []
        for alias in aliases {
            guard alias.providerAuthorized else { continue }
            guard !unique.contains(where: { $0.id == alias.id }) else { continue }
            guard alias.address.utf8.count <= 320, alias.name.utf8.count <= 512,
                  alias.signature.utf8.count <= 32 * 1024 else {
                throw LauncherError("The alias or signature is too long.")
            }
            guard alias.validated(accountAddress: alias.address) else {
                throw LauncherError("Add a provider-authorized standard email address for this alias.")
            }
            unique.append(alias)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(unique), forKey: defaultsKey)
    }

    static func save(_ aliases: [MailAlias], accounts: [NativeMailAccount], defaults: UserDefaults = .standard) throws {
        for alias in aliases {
            guard let account = accounts.first(where: { $0.id == alias.accountID }),
                  alias.validated(accountAddress: account.email),
                  alias.address.caseInsensitiveCompare(account.email) != .orderedSame else {
                throw LauncherError("Add an alias that belongs to a configured provider account.")
            }
        }
        try save(aliases, defaults: defaults)
    }

    static func aliases(for account: NativeMailAccount, defaults: UserDefaults = .standard) -> [MailAlias] {
        load(defaults: defaults).filter {
            $0.accountID == account.id && $0.validated(accountAddress: account.email)
                && $0.address.caseInsensitiveCompare(account.email) != .orderedSame
        }
    }
}

/// A small standalone settings pane. Root settings can embed this view without opening another
/// mail window. Checking the authorization box is required before an alias can be persisted.
struct MailAliasSettingsView: View {
    let accounts: [NativeMailAccount]
    let defaults: UserDefaults
    @State private var selectedAccountID = ""
    @State private var address = ""
    @State private var name = ""
    @State private var signature = ""
    @State private var authorized = false
    @State private var error: String?

    init(accounts: [NativeMailAccount], defaults: UserDefaults = .standard) {
        self.accounts = accounts
        self.defaults = defaults
        _selectedAccountID = State(initialValue: accounts.first?.id ?? "")
    }

    private var aliases: [MailAlias] {
        guard let account = accounts.first(where: { $0.id == selectedAccountID }) else { return [] }
        return MailAliasStore.aliases(for: account, defaults: defaults)
    }

    var body: some View {
        Form {
            Section("Provider-authorized aliases") {
                if accounts.isEmpty {
                    Text("Add a mail account before configuring an alias.").foregroundStyle(.secondary)
                } else {
                    Picker("Account", selection: $selectedAccountID) {
                        ForEach(accounts) { account in
                            Text(account.email).tag(account.id)
                        }
                    }
                    TextField("Alias address", text: $address)
                    TextField("Display name", text: $name)
                    TextField("Signature", text: $signature, axis: .vertical)
                    Toggle("My provider authorizes this address", isOn: $authorized)
                    Text("Jevcast never sends an unchecked From address. The selected account remains the credential and envelope owner.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save alias") { save() }.disabled(!authorized)
                    ForEach(aliases) { alias in
                        HStack {
                            Label(alias.title, systemImage: "checkmark.seal")
                            Spacer()
                            Button("Remove") { remove(alias) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private func save() {
        guard let account = accounts.first(where: { $0.id == selectedAccountID }) else { return }
        let alias = MailAlias(accountID: account.id, address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                              name: name, signature: signature, providerAuthorized: authorized)
        do {
            try MailAliasStore.save(MailAliasStore.load(defaults: defaults) + [alias], accounts: accounts, defaults: defaults)
            address = ""; name = ""; signature = ""; authorized = false; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ alias: MailAlias) {
        do {
            try MailAliasStore.save(MailAliasStore.load(defaults: defaults).filter { $0.id != alias.id }, accounts: accounts, defaults: defaults)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
