import AppKit
import Combine
import LauncherCore

/// App-owned mail services outlive the launcher panel. Demo and test callers supply private stores.
@MainActor
final class MailFeatureCenter: ObservableObject {
    static let shared = MailFeatureCenter()
    let directory: URL
    let schedules: MailScheduleCenter
    let snoozes: MailSnoozeCenter
    let ruleStore: MailRuleStore
    private let defaults: UserDefaults?
    let settingsDefaults: UserDefaults
    private let suppliedAccounts: [NativeMailAccount]?
    @Published var problem: String?
    @Published private(set) var boxes: [MailMailbox] = []
    @Published private(set) var observations: [MailRuleMessage] = []
    @Published private(set) var refreshing = false
    var openMessage: ((Int64) -> Void)?
    private var targets: [String: MailRuleNativeTarget] = [:]
    private var known: Set<String> = []
    private var watching: AnyCancellable?
    private var work: Task<Void, Never>?
    private let startedAt = Date()
    private weak var model: MailModel?
    private var snoozeWatch: AnyCancellable?
    private var smartWatch: AnyCancellable?
    private var didBaseline = false
    private var fullRefreshPending = false

    lazy var rules = MailRulesController(store: ruleStore, observeMessages: { [weak self] in self?.observations ?? [] },
        accountChoices: { [weak self] in self?.accountChoices ?? [] }, execute: { [weak self] action, message in
            guard let self else { throw CancellationError() }
            try await self.execute(action, on: message)
        })
    lazy var smart = MailSmartController(store: MailSmartStore(url: directory.appendingPathComponent("smart.json")), rules: ruleStore,
        observeMessages: { [weak self] in self?.observations ?? [] }, accountChoices: { [weak self] in self?.accountChoices ?? [] },
        junkFolder: { [weak self] account in
            let matches = self?.boxes.filter { $0.accountID == account && $0.role == .junk } ?? []
            guard matches.count == 1, let box = matches.first else { return nil }
            return .init(accountID: account, mailboxID: box.rowID, path: box.path)
        }, openMessage: { [weak self] key in
            if let target = self?.targets[key] { self?.openMessage?(target.summary.rowID) }
        })
    lazy var notifications = MailNotificationCenter(ledgerURL: directory.appendingPathComponent("notifications.json"), defaults: defaults,
        showOnNotch: { alert in guard !MailIOPolicy.isOffline else { return }; NotchAlertController.shared.show(alert) },
        openMessage: { [weak self] key in if let target = self?.targets[key] { self?.openMessage?(target.summary.rowID) } })

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jevcast/MailFeatures"),
         defaults: UserDefaults? = .standard, accounts: [NativeMailAccount]? = nil) {
        self.directory = directory; self.defaults = defaults
        settingsDefaults = defaults ?? UserDefaults(suiteName: "Jevcast.MailFeatures." + UUID().uuidString)!
        suppliedAccounts = accounts
        schedules = MailScheduleCenter(store: MailScheduleStore(directory: directory.appendingPathComponent("Scheduled")))
        snoozes = MailSnoozeCenter(store: MailSnoozeStore(directory: directory.appendingPathComponent("Snoozed")))
        ruleStore = MailRuleStore(root: directory.appendingPathComponent("Rules"))
    }

    var accountChoices: [MailRuleAccountChoice] {
        (suppliedAccounts ?? (MailIOPolicy.isOffline ? [] : NativeMailCenter.loadAccounts())).map { account in
            .init(id: account.id, title: account.email, folders: boxes.filter { $0.accountID == account.id }.map {
                .init(id: $0.rowID, name: $0.name, path: $0.path)
            })
        }
    }

    func archive() throws -> MailArchiveStore { try MailArchiveStore(root: directory.appendingPathComponent("Archive")) }

    func start(model: MailModel) {
        model.scheduledDraftIsProtected = { [weak self] id in
            self?.schedules.entries.contains { $0.draft.id == id && $0.state != .cancelled } == true
        }
        guard !MailIOPolicy.isOffline, watching == nil else { return }
        self.model = model
        schedules.setAccountCheck { item in
            guard NativeMailCenter.isActive else { return false }
            let identities = try? await MailSendingIdentity.load(backend: .jevcast)
            return identities?.contains { $0.accountID == item.account.accountID && $0.address == item.account.address } == true
        }
        schedules.setSubmission { [weak self, weak model] entry in
            guard let self, let model else { throw CancellationError() }
            // The schedule has already saved its dispatch checkpoint. The delivery journal
            // independently protects the app's normal send recovery and Sent-copy repair.
            let ready = try await model.serverDrafts.prepareForSend(entry.draft)
            model.recordDelivery(ready, state: .sending)
            try await model.saveCompositionAsync()
            var accepted = false
            do {
                let result = try await MailModel.deliver(ready, nil)
                accepted = true
                model.recordSubmission(ready, result)
                try await model.saveCompositionAsync()
                await model.serverDrafts.completedSend(ready)
                return result
            } catch {
                if !accepted {
                    model.recordDelivery(ready, state: .uncertain, note: "Scheduled delivery needs review: " + error.localizedDescription)
                }
                try? await model.saveCompositionAsync()
                self.problem = "A scheduled message needs review. Check Scheduled and Sent before sending again."
                throw error
            }
        }
        snoozeWatch = snoozes.$entries.sink { [weak model] entries in
            model?.snoozedMessageKeys = Set(entries.filter { $0.state == .scheduled }.map { $0.account.accountID + ":" + $0.summary.messageKey })
        }
        smartWatch = smart.$state.sink { [weak model] in model?.vipAddresses = $0.vipAddresses }
        schedules.start(); snoozes.start()
        watching = NotificationCenter.default.publisher(for: NativeMailCenter.changed)
            .debounce(for: .milliseconds(700), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() { watching = nil; work?.cancel(); work = nil; schedules.stop(); snoozes.stop() }

    /// Only new Inbox arrivals after launch can trigger automatic rules or notices.
    /// Explicit management previews can scan every downloaded message without applying anything.
    func refresh(full: Bool = false) {
        guard !MailIOPolicy.isOffline, NativeMailCenter.isActive else { return }
        if refreshing { fullRefreshPending = fullRefreshPending || full; return }
        refreshing = true
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshing = false
                if fullRefreshPending { fullRefreshPending = false; refresh(full: true) }
            }
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try MailFeatureSnapshot.read(root: NativeMailCenter.root.path, full: full)
                }.value
                try Task.checkCancellation()
                boxes = snapshot.boxes
                if full || observations.isEmpty { observations = snapshot.observations }
                targets.merge(snapshot.targets) { _, new in new }
                let incoming = snapshot.observations.filter { observation in
                    snapshot.boxes.contains { $0.rowID == observation.mailboxID && $0.role == .inbox }
                }
                let fresh = incoming.filter { !self.known.contains($0.id) && $0.receivedAt >= self.startedAt }
                known = Set(incoming.map(\.id))
                let notices = incoming.map { MailNotificationMessage(id: $0.id, accountID: $0.accountID, sender: $0.from,
                    subject: $0.subject, receivedAt: $0.receivedAt, isRead: $0.isRead) }
                notifications.observe(notices, initialLoad: !didBaseline)
                if didBaseline && !fresh.isEmpty { rules.reload(); _ = await rules.applyNew(fresh) }
                didBaseline = true
                let identities = NativeMailCenter.loadAccounts().map(MailAccountIdentity.init)
                try snoozes.reconcile(accounts: identities)
                let senders = try await MailSendingIdentity.load(backend: .jevcast)
                try schedules.reconcile(accounts: senders.map(MailAccountIdentity.init))
                model?.vipAddresses = smart.state.vipAddresses
            } catch is CancellationError {} catch { problem = error.localizedDescription }
        }
    }

    func openSnoozed(_ entry: MailSnoozeEntry, page: MailPage) {
        guard let target = targets[entry.account.accountID + ":" + entry.summary.messageKey] else {
            problem = "This message is not in the current cache. Check its account and refresh Mail."; return
        }
        page.show(target.summary.rowID)
    }

    private func execute(_ action: MailRuleAction, on observation: MailRuleMessage) async throws {
        guard NativeMailCenter.isActive, let expected = targets[observation.id] else {
            throw LauncherError("The rule's message is no longer available. Refresh the preview.")
        }
        let current = try await Task.detached(priority: .utility) {
            let boxes = try MailStore.mailboxes(root: NativeMailCenter.root.path)
            let query = MailStore.Query(mailboxes: [expected.mailbox.rowID], rowIDs: [expected.summary.rowID], limit: 1)
            let rows = try MailStore.messages(root: NativeMailCenter.root.path, query)
            guard let row = rows.first, row.messageKey == expected.summary.messageKey,
                  row.subject == expected.summary.subject, row.senderAddress == expected.summary.senderAddress,
                  let box = boxes.first(where: { $0.rowID == expected.mailbox.rowID && $0.url == expected.mailbox.url }) else {
                throw LauncherError("This message changed. Refresh the preview before applying the rule.")
            }
            return (row, box, boxes)
        }.value
        switch action {
        case .markRead(let value): try await MailActions.setRead(value, current.0, in: current.1)
        case .markFlagged(let value): try await MailActions.setFlagged(value, current.0, in: current.1)
        case let .moveToFolder(account, mailbox, path):
            guard account == current.1.accountID,
                  let target = current.2.first(where: { $0.rowID == mailbox && $0.accountID == account && $0.path == path }),
                  ![.trash].contains(target.role) else { throw LauncherError("Choose a current folder in the same account.") }
            try await MailActions.move(current.0, from: current.1, to: target)
        }
    }
}
