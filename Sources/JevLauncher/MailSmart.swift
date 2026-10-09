import SwiftUI
import LauncherCore

struct MailJunkFolderIdentity: Equatable, Sendable {
    let accountID: String
    let mailboxID: Int64
    let path: String
}

@MainActor
final class MailSmartController: ObservableObject {
    @Published private(set) var state: MailSmartState
    @Published var message: String?
    @Published private(set) var previewCount = 0
    @Published private(set) var previewMessages: [MailRuleMessage] = []

    let store: MailSmartStore
    private let rules: MailRuleStore
    private let observeMessages: () -> [MailRuleMessage]
    private let junkFolder: (String) -> MailJunkFolderIdentity?
    private let accountChoices: () -> [MailRuleAccountChoice]
    private let openMessage: (String) -> Void

    init(store: MailSmartStore = MailSmartStore(), rules: MailRuleStore = MailRuleStore(),
         observeMessages: @escaping () -> [MailRuleMessage] = { [] },
         accountChoices: @escaping () -> [MailRuleAccountChoice] = { [] },
         junkFolder: @escaping (String) -> MailJunkFolderIdentity? = { _ in nil },
         openMessage: @escaping (String) -> Void = { _ in }) {
        self.store = store; self.rules = rules; self.observeMessages = observeMessages; self.junkFolder = junkFolder; self.accountChoices = accountChoices; self.openMessage = openMessage
        state = store.load()
        message = store.loadError.map { "Saved smart mailboxes could not be read: \($0)" }
    }

    var accounts: [MailRuleAccountChoice] { accountChoices() }
    var vipAddresses: Set<String> { state.vipAddresses }

    func reload() {
        state = store.load()
        if let error = store.loadError { message = "Saved smart mailboxes could not be read: \(error)" }
    }

    func saveMailbox(_ mailbox: MailSmartMailbox) {
        do { try store.saveMailbox(mailbox); reload() }
        catch { message = error.localizedDescription }
    }

    func deleteMailbox(id: UUID) {
        do { try store.deleteMailbox(id: id); reload() }
        catch { message = error.localizedDescription }
    }

    func preview(_ mailbox: MailSmartMailbox) {
        previewMessages = observeMessages().filter(mailbox.matches)
        previewCount = previewMessages.count
    }

    func open(messageID: String) { openMessage(messageID) }

    func isVIP(_ address: String) -> Bool {
        state.vipAddresses.contains(MailSmartStore.normalize(address))
    }

    func setVIP(_ address: String, enabled: Bool) {
        do { try store.setVIP(address, enabled: enabled); reload() }
        catch { message = error.localizedDescription }
    }

    func blockSender(_ address: String, accountID: String) {
        let normalized = MailSmartStore.normalize(address)
        if state.blockedSenders.contains(normalized) {
            message = "This sender is already blocked."; return
        }
        guard let target = junkFolder(accountID) else {
            message = "Select the current Junk folder for this account before blocking a sender."; return
        }
        do {
            guard store.loadError == nil else {
                message = "Saved smart mailboxes could not be read: \(store.loadError ?? "unknown error")"; return
            }
            let rule = try store.blockedSenderRule(address, accountID: target.accountID, junkMailboxID: target.mailboxID, junkPath: target.path)
            try rules.saveRule(rule)
            do { try store.addBlockedSender(address, ruleID: rule.id) }
            catch {
                try? rules.deleteRule(id: rule.id)
                throw error
            }
            reload()
            message = "Blocked \(address) and added a move-to-Junk rule."
        } catch { message = error.localizedDescription }
    }

    func unblockSender(_ address: String) {
        let normalized = MailSmartStore.normalize(address)
        guard state.blockedSenders.contains(normalized) else { return }
        let loadedRules = rules.loadRules()
        guard rules.rulesError == nil else {
            message = "Saved rules could not be read: \(rules.rulesError ?? "unknown error")"; return
        }
        let generatedID = state.blockedRuleIDs[normalized]
        guard let generatedID else {
            message = "This block has no recorded generated rule. Review Rules and remove it there before unblocking."
            return
        }
        let candidate = loadedRules.first { rule in
            guard rule.id == generatedID,
                  rule.name == "Block \(normalized)",
                  rule.predicate == MailRulePredicate(from: normalized),
                  rule.actions.count == 1 else { return false }
            guard case .moveToFolder = rule.actions[0] else { return false }
            return true
        }
        if loadedRules.contains(where: { $0.id == generatedID }), candidate == nil {
            message = "The generated block rule changed. Review it in Rules before unblocking."
            return
        }
        do {
            if candidate != nil { try rules.deleteRule(id: generatedID) }
            try store.removeBlockedSender(normalized)
            reload()
            message = candidate == nil ? "Removed the blocked sender entry. No matching generated rule remained." : "Unblocked \(normalized)."
        } catch { message = error.localizedDescription }
    }
}

struct MailSmartDraft: Equatable {
    var id: UUID?
    var name = ""
    var from = ""
    var to = ""
    var subject = ""
    var accountID = ""

    init() {}
    init(mailbox: MailSmartMailbox) {
        id = mailbox.id; name = mailbox.name; from = mailbox.predicate.from ?? ""; to = mailbox.predicate.to ?? ""
        subject = mailbox.predicate.subject ?? ""; accountID = mailbox.predicate.accountID ?? ""
    }

    func build(existing: MailSmartMailbox? = nil, now: Date = Date()) -> MailSmartMailbox? {
        let predicate = MailRulePredicate(from: from.nilIfBlank, to: to.nilIfBlank, subject: subject.nilIfBlank, accountID: accountID.nilIfBlank)
        guard !name.isNilOrEmpty, !predicate.isEmpty else { return nil }
        return MailSmartMailbox(id: existing?.id ?? id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), predicate: predicate,
                                createdAt: existing?.createdAt ?? now)
    }
}

/// Saved smart mailboxes and address lists stay inside the launcher mail workspace.
struct MailSmartView: View {
    @ObservedObject var controller: MailSmartController
    @State private var selectedID: UUID?
    @State private var draft = MailSmartDraft()
    @State private var vipAddress = ""
    @State private var blockedAddress = ""
    @State private var blockedAccount = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Button { newMailbox() } label: { Label("Add", systemImage: "plus") }
                    Spacer()
                    if let selectedID { Button("Delete", role: .destructive) { controller.deleteMailbox(id: selectedID); newMailbox() } }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                Divider()
                List(selection: $selectedID) {
                    Section("Smart mailboxes") {
                    ForEach(controller.state.mailboxes) { mailbox in
                        HStack { Image(systemName: "tray.full"); Text(mailbox.name) }
                            .tag(mailbox.id as UUID?)
                    }
                    }
                    Section("Preview matches") {
                        ForEach(controller.previewMessages) { message in
                            Button { controller.open(messageID: message.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: controller.isVIP(message.from) ? "star.fill" : "envelope")
                                        .foregroundStyle(controller.isVIP(message.from) ? .yellow : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(message.subject.isEmpty ? "(No subject)" : message.subject).lineLimit(1)
                                        Text(message.from).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text("Open").font(.caption)
                                }
                            }.buttonStyle(.plain)
                        }
                        if controller.previewMessages.isEmpty { Text("Choose Preview to list matching messages.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Section("VIPs") {
                        ForEach(controller.state.vipAddresses.sorted(), id: \.self) { address in
                            HStack { Image(systemName: "star.fill").foregroundStyle(.yellow); Text(address).lineLimit(1).help(address); Spacer(); Button("Remove") { controller.setVIP(address, enabled: false) }.buttonStyle(.link) }
                        }
                    }
                    Section("Blocked senders") {
                        ForEach(controller.state.blockedSenders.sorted(), id: \.self) { address in
                            HStack { Text(address).lineLimit(1).help(address).foregroundStyle(.secondary); Spacer(); Button("Unblock") { controller.unblockSender(address) }.buttonStyle(.link) }
                        }
                    }
                }
            }
            .frame(width: 220)
            Divider()
            Form {
                Section("Saved mailbox") {
                    TextField("Name", text: $draft.name)
                    TextField("From contains", text: $draft.from)
                    TextField("To contains", text: $draft.to)
                    TextField("Subject contains", text: $draft.subject)
                    Picker("Account", selection: $draft.accountID) {
                        Text("Any account").tag("")
                        ForEach(controller.accounts) { account in Text(account.title).tag(account.id) }
                    }
                    HStack {
                        Button("Save") { saveMailbox() }.keyboardShortcut(.defaultAction)
                        Button("Preview") { previewMailbox() }
                        if selectedID != nil { Button("Delete", role: .destructive) { deleteMailbox() } }
                    }
                    if controller.previewCount > 0 { Text("Preview: \(controller.previewCount) matching message\(controller.previewCount == 1 ? "" : "s").") .font(.caption).foregroundStyle(.secondary) }
                }
                Section("VIP") {
                    TextField("Email address", text: $vipAddress)
                    Button("Add VIP") { addVIP() }
                    Text("VIPs are saved for the launcher to highlight in its mail list.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Block sender") {
                    TextField("Sender address", text: $blockedAddress)
                    Picker("Account", selection: $blockedAccount) {
                        Text("Choose an account").tag("")
                        ForEach(controller.accounts) { account in Text(account.title).tag(account.id) }
                    }
                    Button("Block and move future mail to Junk") { blockSender() }
                    Text("The current Junk mailbox identity is validated again when the generated rule runs.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = controller.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 400)
        }
        .onAppear { selectFirst() }
        .onChange(of: selectedID) { _, id in load(id) }
    }

    private func selectFirst() { guard selectedID == nil else { return }; selectedID = controller.state.mailboxes.first?.id; load(selectedID) }
    private func load(_ id: UUID?) { draft = controller.state.mailboxes.first(where: { $0.id == id }).map(MailSmartDraft.init(mailbox:)) ?? MailSmartDraft() }
    private func newMailbox() { selectedID = nil; draft = MailSmartDraft(); controller.message = nil }
    private func saveMailbox() {
        guard let mailbox = draft.build(existing: controller.state.mailboxes.first(where: { $0.id == draft.id })) else {
            controller.message = "Give the smart mailbox a name and one filter."; return
        }
        controller.saveMailbox(mailbox); selectedID = mailbox.id
    }
    private func previewMailbox() {
        guard let mailbox = draft.build(existing: controller.state.mailboxes.first(where: { $0.id == draft.id })) else { controller.message = "Save the smart mailbox before previewing it."; return }
        controller.preview(mailbox)
    }
    private func deleteMailbox() {
        guard let id = selectedID else { return }; controller.deleteMailbox(id: id); newMailbox()
    }
    private func addVIP() { controller.setVIP(vipAddress, enabled: true); vipAddress = "" }
    private func blockSender() { controller.blockSender(blockedAddress, accountID: blockedAccount); blockedAddress = "" }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value
    }
    var isNilOrEmpty: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
