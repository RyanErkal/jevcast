import AppKit
import LauncherCore

struct MailSendingIdentity: Identifiable, Equatable {
    let accountID: String
    let address: String
    let name: String
    let signature: String
    /// The configured account address that owns the credential and SMTP envelope.
    /// Nil for Apple Mail identities, where Mail owns this mapping.
    let accountAddress: String?
    /// True only for the account address or a provider-authorized alias.
    let providerAuthorized: Bool
    var id: String { accountID + ":" + address.lowercased() }
    var isAlias: Bool { accountAddress.map { $0.caseInsensitiveCompare(address) != .orderedSame } ?? false }
    var title: String { (name.isEmpty ? address : name + " <" + address + ">") + (isAlias ? " (alias)" : "") }

    init(accountID: String, address: String, name: String, signature: String,
         accountAddress: String? = nil, providerAuthorized: Bool = true) {
        self.accountID = accountID; self.address = address; self.name = name; self.signature = signature
        self.accountAddress = accountAddress; self.providerAuthorized = providerAuthorized
    }

    /// A native identity must have a canonical account owner. The transport authenticates and
    /// envelopes with that owner while the selected, provider-authorized address is the From.
    func canSend(backend: MailBackend) -> Bool {
        providerAuthorized && (backend == .appleMail || accountAddress != nil)
    }

    func nativeSender(for account: NativeMailAccount) throws -> NativeMailSender {
        guard accountID == account.id, canSend(backend: .jevcast), let accountAddress else {
            throw LauncherError("This provider alias is no longer authorized. Choose the account address or a confirmed provider-authorized alias.")
        }
        return try NativeMailSender(address: address, name: name, accountAddress: accountAddress,
                                    providerAuthorized: providerAuthorized).validated(for: account)
    }

    /// Re-reads only local account/alias configuration immediately before delivery. Apple Mail
    /// remains the owner of its own account mapping, so its already-selected identity is accepted.
    static func configuredForSend(accountID: String, address: String, backend: MailBackend,
                                  name: String = "") -> MailSendingIdentity? {
        guard backend == .jevcast else {
            return MailSendingIdentity(accountID: accountID, address: address, name: name, signature: "",
                                       accountAddress: address, providerAuthorized: true)
        }
        guard let account = NativeMailCenter.loadAccounts().first(where: { $0.id == accountID }) else { return nil }
        if account.email.caseInsensitiveCompare(address) == .orderedSame {
            return MailSendingIdentity(accountID: account.id, address: account.email, name: account.name,
                                       signature: account.signature ?? "", accountAddress: account.email,
                                       providerAuthorized: true)
        }
        guard let alias = MailAliasStore.aliases(for: account).first(where: { $0.address.caseInsensitiveCompare(address) == .orderedSame }) else { return nil }
        return MailSendingIdentity(accountID: account.id, address: alias.address, name: alias.name,
                                   signature: alias.signature, accountAddress: account.email,
                                   providerAuthorized: alias.providerAuthorized)
    }

    static func load(backend: MailBackend) async throws -> [MailSendingIdentity] {
        try MailIOPolicy.requireOnline()
        if backend == .jevcast {
            var result = NativeMailCenter.loadAccounts().flatMap { account -> [MailSendingIdentity] in
                let primary = MailSendingIdentity(accountID: account.id, address: account.email, name: account.name,
                                                  signature: account.signature ?? "", accountAddress: account.email,
                                                  providerAuthorized: true)
                let aliases = MailAliasStore.aliases(for: account).map {
                    MailSendingIdentity(accountID: account.id, address: $0.address, name: $0.name,
                                       signature: $0.signature, accountAddress: account.email,
                                       providerAuthorized: $0.providerAuthorized)
                }
                return [primary] + aliases
            }
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return result
        }
        try await MailActions.ensureRunning()
        let output = try await AppleScript.run(MailScripts.sendingIdentities, app: MailActions.bundleID, name: "Mail", timeout: 20)
        return parse(output)
    }

    static func parse(_ output: String) -> [MailSendingIdentity] {
        var seen: Set<String> = []
        return output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, !fields[0].isEmpty,
                  let address = try? MailActions.addresses(fields[1]), address.count == 1, address[0] == fields[1] else { return nil }
            let value = MailSendingIdentity(accountID: fields[0], address: fields[1], name: fields[2], signature: "",
                                            accountAddress: nil, providerAuthorized: true)
            return seen.insert(value.id).inserted ? value : nil
        }
    }
}

extension MailModel {
    func loadSenders() {
        let backend = MailBackend.current
        Task { @MainActor [weak self] in
            do {
                let identities = try await MailSendingIdentity.load(backend: backend)
                guard let self, backend == MailBackend.current else { return }
                self.senders = identities
                if var draft = self.draft, draft.fromAccountID == nil {
                    self.selectInitialSender(&draft)
                    self.draft = draft
                }
            } catch {
                guard !MailIOPolicy.isOffline else { return }
                self?.banner = "Sending accounts could not be read: " + error.localizedDescription
            }
        }
    }

    func selectInitialSender(_ draft: inout Draft) {
        guard draft.backend == MailBackend.current.rawValue else { return }
        let accountID = draft.original.flatMap(actionBox)?.accountID
        let candidates = accountID.map { id in senders.filter { $0.accountID == id } } ?? senders
        let delivered = draft.source.map { source in
            Set(["Delivered-To", "X-Original-To", "To", "Cc"].flatMap {
                MailAddress.list(source.message.header($0) ?? "").map { $0.address.lowercased() }
            })
        } ?? []
        // A reply must stay with its original account. Never silently use another one.
        let preferred = candidates.first { delivered.contains($0.address.lowercased()) }
            ?? candidates.first { $0.id == UserDefaults.standard.string(forKey: "mailDefaultSender." + draft.backend) }
            ?? candidates.first { !$0.isAlias }
            ?? candidates.first
        draft.fromAccountID = preferred?.accountID; draft.fromAddress = preferred?.address
        draft.fromName = preferred?.name
        draft.fromIdentityID = preferred?.id
        draft.ownAddresses = senders.map(\.address)
    }

    func selectSender(_ id: String) {
        guard let identity = senders.first(where: { $0.id == id }), var draft else { return }
        draft.fromAccountID = identity.accountID; draft.fromAddress = identity.address
        draft.fromName = identity.name; draft.fromIdentityID = identity.id
        draft.senderWasChosen = true
        self.draft = draft
        if draft.mode == .new { UserDefaults.standard.set(id, forKey: "mailDefaultSender." + draft.backend) }
    }

    func insertSignature() {
        guard var draft, let sender = senders.first(where: { $0.accountID == draft.fromAccountID && $0.address == draft.fromAddress }),
              !sender.signature.isEmpty else { return }
        let text = NSMutableAttributedString(attributedString: MailRichText.attributed(draft.richText, plain: draft.body))
        text.append(NSAttributedString(string: (draft.body.isEmpty ? "" : "\n\n") + sender.signature,
                                       attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]))
        draft.body = text.string
        draft.richText = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        self.draft = draft
    }
}
