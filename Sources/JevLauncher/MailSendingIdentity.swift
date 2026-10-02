import AppKit
import LauncherCore

struct MailSendingIdentity: Identifiable, Equatable {
    let accountID: String
    let address: String
    let name: String
    let signature: String
    var id: String { accountID + ":" + address.lowercased() }
    var title: String { name.isEmpty ? address : name + " <" + address + ">" }

    static func load(backend: MailBackend) async throws -> [MailSendingIdentity] {
        try MailIOPolicy.requireOnline()
        if backend == .jevcast {
            return NativeMailCenter.loadAccounts().map {
                .init(accountID: $0.id, address: $0.email, name: $0.name, signature: $0.signature ?? "")
            }
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
            let value = MailSendingIdentity(accountID: fields[0], address: fields[1], name: fields[2], signature: "")
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
            ?? candidates.first
        draft.fromAccountID = preferred?.accountID; draft.fromAddress = preferred?.address
        draft.ownAddresses = senders.map(\.address)
    }

    func selectSender(_ id: String) {
        guard let identity = senders.first(where: { $0.id == id }), var draft else { return }
        draft.fromAccountID = identity.accountID; draft.fromAddress = identity.address
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
