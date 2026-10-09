import SwiftUI
import LauncherCore

struct MailRuleFolderChoice: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let path: String
}

struct MailRuleAccountChoice: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let folders: [MailRuleFolderChoice]
}

/// Launcher-owned rule coordinator. It has no mail reader of its own: the root supplies current
/// observations and the native action closure, so previews never become hidden retroactive runs.
@MainActor
final class MailRulesController: ObservableObject {
    @Published private(set) var rules: [MailRule] = []
    @Published private(set) var preview: MailRulePreview?
    @Published var message: String?

    let store: MailRuleStore
    private let observeMessages: () -> [MailRuleMessage]
    private let engine: MailRuleEngine
    private let accountChoices: () -> [MailRuleAccountChoice]

    init(store: MailRuleStore = MailRuleStore(), observeMessages: @escaping () -> [MailRuleMessage] = { [] },
         accountChoices: @escaping () -> [MailRuleAccountChoice] = { [] },
         execute: @escaping MailRuleEngine.ActionExecutor = { _, _ in
             throw MailRuleExecutionError.needsReview("No mail action executor is connected.")
         }) {
        self.store = store
        self.observeMessages = observeMessages
        self.accountChoices = accountChoices
        self.engine = MailRuleEngine(store: store, execute: execute)
        reload()
    }

    var accounts: [MailRuleAccountChoice] { accountChoices() }

    func reload() {
        rules = store.loadRules()
        preview = nil
        if let error = store.rulesError {
            message = "Saved rules could not be read: \(error)"
            return
        }
        do { try store.recoverRunningApplications() }
        catch { message = "Rule application history could not be read: \(error.localizedDescription)" }
    }

    func save(_ rule: MailRule) {
        do { try store.saveRule(rule); reload() }
        catch { message = error.localizedDescription }
    }

    func delete(id: UUID) {
        do { try store.deleteRule(id: id); reload() }
        catch { message = error.localizedDescription }
    }

    func move(id: UUID, by delta: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        do { try store.moveRule(id: id, to: index + delta); reload() }
        catch { message = error.localizedDescription }
    }

    func preview(ruleID: UUID) {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return }
        preview = engine.preview(rule: rule, messages: observeMessages())
    }

    /// Root calls this only with messages newly reported by sync. It never reads the mailbox or
    /// catches up old messages, so existing mail changes remain behind the explicit preview/apply UI.
    func applyNew(_ messages: [MailRuleMessage], now: Date = Date()) async -> [MailRuleApplyResult] {
        var results: [MailRuleApplyResult] = []
        for rule in rules where rule.enabled { results.append(await engine.apply(rule: rule, messages: messages, now: now)) }
        return results
    }

    func applyPreview() async {
        guard let preview, let rule = rules.first(where: { $0.id == preview.ruleID }) else { return }
        let result = await engine.apply(rule: rule, matches: preview.messages)
        self.preview = nil
        message = "Applied \(result.applied.count) action\(result.applied.count == 1 ? "" : "s"); "
            + "skipped \(result.skipped.count), failed \(result.failed.count), needs review \(result.needsReview.count)."
    }
}

struct MailRuleDraft: Equatable {
    var id: UUID?
    var name = ""
    var enabled = true
    var from = ""
    var to = ""
    var subject = ""
    var accountID = ""
    var markRead: Bool?
    var markFlagged: Bool?
    var moveAccountID = ""
    var moveMailboxID = ""
    var movePath = ""

    init() {}

    init(rule: MailRule) {
        id = rule.id; name = rule.name; enabled = rule.enabled
        from = rule.predicate.from ?? ""; to = rule.predicate.to ?? ""; subject = rule.predicate.subject ?? ""; accountID = rule.predicate.accountID ?? ""
        for action in rule.actions {
            switch action {
            case .markRead(let value): markRead = value
            case .markFlagged(let value): markFlagged = value
            case let .moveToFolder(accountID, mailboxID, path): moveAccountID = accountID; moveMailboxID = String(mailboxID); movePath = path
            }
        }
    }

    func build(existing: MailRule? = nil, moveFolder: MailRuleFolderChoice? = nil, now: Date = Date()) -> MailRule? {
        let conditions = MailRulePredicate(from: from.nilIfBlank, to: to.nilIfBlank, subject: subject.nilIfBlank, accountID: accountID.nilIfBlank)
        var actions: [MailRuleAction] = []
        if let markRead { actions.append(.markRead(markRead)) }
        if let markFlagged { actions.append(.markFlagged(markFlagged)) }
        let selectedPath = moveFolder?.path ?? movePath
        if let mailboxID = Int64(moveMailboxID), !moveAccountID.isNilOrEmpty, !selectedPath.isNilOrEmpty {
            actions.append(.moveToFolder(accountID: moveAccountID.trimmingCharacters(in: .whitespacesAndNewlines), mailboxID: mailboxID,
                                         path: selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard !name.isNilOrEmpty, !conditions.isEmpty, !actions.isEmpty else { return nil }
        return MailRule(id: existing?.id ?? id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), enabled: enabled,
                        predicate: conditions, actions: actions, order: existing?.order ?? 0,
                        createdAt: existing?.createdAt ?? now, updatedAt: now)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    var isNilOrEmpty: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// An embeddable management surface. Root places this in the existing launcher mail page/sidebar;
/// it does not create an NSWindow or compose window.
struct MailRulesView: View {
    @ObservedObject var controller: MailRulesController
    @State private var selectedID: UUID?
    @State private var draft = MailRuleDraft()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Button { newRule() } label: { Label("Add Rule", systemImage: "plus") }
                    Spacer()
                    if let selectedID {
                        Button { controller.move(id: selectedID, by: -1) } label: { Image(systemName: "chevron.up") }
                        Button { controller.move(id: selectedID, by: 1) } label: { Image(systemName: "chevron.down") }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                Divider()
                List(selection: $selectedID) {
                ForEach(controller.rules) { rule in
                    HStack {
                        Image(systemName: rule.enabled ? "line.3.horizontal.decrease.circle" : "pause.circle")
                        Text(rule.name).lineLimit(1)
                        Spacer()
                        Text("\(rule.actions.count)").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(rule.id as UUID?)
                    .contextMenu {
                        Button("Move Up") { controller.move(id: rule.id, by: -1) }
                        Button("Move Down") { controller.move(id: rule.id, by: 1) }
                        Divider()
                        Button("Delete", role: .destructive) { controller.delete(id: rule.id) }
                    }
                }
            }
            }
            .frame(width: 220)
            Divider()
            Form {
                Section("Rule") {
                    TextField("Name", text: $draft.name)
                    Toggle("Enabled", isOn: $draft.enabled)
                }
                Section("Match") {
                    TextField("From contains", text: $draft.from)
                    TextField("To contains", text: $draft.to)
                    TextField("Subject contains", text: $draft.subject)
                    Picker("Account", selection: $draft.accountID) {
                        Text("Any account").tag("")
                        ForEach(controller.accounts) { account in Text(account.title).tag(account.id) }
                    }
                }
                Section("Actions") {
                    Picker("Read", selection: Binding<Bool?>(get: { draft.markRead }, set: { draft.markRead = $0 })) {
                        Text("No change").tag(nil as Bool?)
                        Text("Mark read").tag(true as Bool?)
                        Text("Mark unread").tag(false as Bool?)
                    }
                    Picker("Flag", selection: Binding<Bool?>(get: { draft.markFlagged }, set: { draft.markFlagged = $0 })) {
                        Text("No change").tag(nil as Bool?)
                        Text("Flag").tag(true as Bool?)
                        Text("Unflag").tag(false as Bool?)
                    }
                    Picker("Move account", selection: Binding(get: { draft.moveAccountID }, set: {
                        draft.moveAccountID = $0; draft.moveMailboxID = ""; draft.movePath = ""
                    })) {
                        Text("Do not move").tag("")
                        ForEach(controller.accounts) { account in Text(account.title).tag(account.id) }
                    }
                    Picker("Move folder", selection: $draft.moveMailboxID) {
                        Text("Choose a folder").tag("")
                        ForEach(controller.accounts.first(where: { $0.id == draft.moveAccountID })?.folders ?? []) { folder in
                            Text(folder.name).tag(String(folder.id))
                        }
                    }
                    Text("Move identity is checked again when the action runs.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    Button("Preview Matches") { preview() }
                    if controller.preview != nil {
                        Button("Apply to Preview…") { Task { await controller.applyPreview() } }
                    }
                    if let id = selectedID { Button("Delete", role: .destructive) { controller.delete(id: id); newRule() } }
                }
                if let preview = controller.preview {
                    Text("Preview: \(preview.count) exact match\(preview.count == 1 ? "" : "es"). Apply is explicit and runs only for these messages.")
                        .font(.caption).foregroundStyle(.secondary)
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

    private func selectFirst() {
        guard selectedID == nil else { return }
        selectedID = controller.rules.first?.id
        load(selectedID)
    }

    private func load(_ id: UUID?) {
        draft = controller.rules.first(where: { $0.id == id }).map(MailRuleDraft.init(rule:)) ?? MailRuleDraft()
    }

    private func newRule() { selectedID = nil; draft = MailRuleDraft(); controller.message = nil }

    private func save() {
        let selectedFolder = controller.accounts.first(where: { $0.id == draft.moveAccountID })?.folders.first(where: { String($0.id) == draft.moveMailboxID })
        guard let rule = draft.build(existing: controller.rules.first(where: { $0.id == draft.id }), moveFolder: selectedFolder) else {
            controller.message = "Give the rule a name, one condition, and one action."; return
        }
        controller.save(rule); selectedID = rule.id
    }

    private func preview() {
        guard let id = draft.id ?? selectedID else { controller.message = "Save the rule before previewing it."; return }
        controller.preview(ruleID: id)
    }
}
