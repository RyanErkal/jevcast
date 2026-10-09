import Combine
import Foundation
import LauncherCore

enum MailScheduleError: LocalizedError, Equatable {
    case dateInPast
    case invalidAccount
    case unavailableAccount
    case invalidDraft(String)
    case duplicateDraft
    case notFound
    case cannotEdit
    case cannotCancelInFlight
    case noSubmission
    case sentCheckRequired
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .dateInPast: return "Choose a future time."
        case .invalidAccount: return "Choose the account that owns this draft."
        case .unavailableAccount: return "This account changed or is disconnected. Review the message before scheduling it."
        case .invalidDraft(let reason): return reason
        case .duplicateDraft: return "This draft is already scheduled."
        case .notFound: return "The scheduled message is no longer available."
        case .cannotEdit: return "This scheduled message is already being handed off or was already submitted."
        case .cannotCancelInFlight: return "This message is already being handed off. Review it after the handoff finishes."
        case .noSubmission: return "Scheduled sending is not connected to the mail transport. Review this message before sending it."
        case .sentCheckRequired: return "Check Sent before rescheduling this message."
        case .persistence(let message): return message
        }
    }
}

/// Durable local Send Later state. No helper process is installed: the app's lifecycle owns the
/// timer, so it runs while Jevcast is awake and running, including while its launcher is hidden.
@MainActor
final class MailScheduleCenter: ObservableObject {
    typealias Submission = @MainActor (MailScheduleEntry) async throws -> MailSubmission
    /// The root rechecks the live account immediately before handing the snapshot to MailModel.
    /// This is separate from the persisted identity check, which protects a relaunch.
    typealias AccountCheck = @MainActor (MailScheduleEntry) async -> Bool

    @Published private(set) var entries: [MailScheduleEntry] = []
    @Published private(set) var persistenceProblem: String?

    let store: MailScheduleStore
    let clock: any MailScheduleClock
    private var submission: Submission?
    private var accountCheck: AccountCheck?
    private let lateTolerance: TimeInterval
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    private var dispatchingID: UUID?
    private var dispatchWork: [UUID: Task<Void, Never>] = [:]
    private var persistenceBlocked = false

    init(store: MailScheduleStore = .standard, clock: any MailScheduleClock = MailSystemClock(),
         submission: Submission? = nil, lateTolerance: TimeInterval = 2, automaticallyStart: Bool = false) {
        self.store = store
        self.clock = clock
        self.submission = submission
        self.lateTolerance = max(0, lateTolerance)
        do {
            let loaded = try store.load().entries
            let normalized = Self.normalizedForLaunch(loaded, now: clock.now())
            entries = normalized.entries
            if normalized.changed {
                do { try store.save(.init(entries: normalized.entries)) }
                catch {
                    persistenceProblem = error.localizedDescription
                    persistenceBlocked = true
                }
            }
        } catch {
            persistenceProblem = error.localizedDescription
            entries = []
            persistenceBlocked = true
        }
        if automaticallyStart { start() }
    }

    func setSubmission(_ submission: @escaping Submission) { self.submission = submission }
    func setAccountCheck(_ accountCheck: @escaping AccountCheck) { self.accountCheck = accountCheck }

    var scheduled: [MailScheduleEntry] { entries.filter { $0.state == .scheduled } }
    var dispatching: [MailScheduleEntry] { entries.filter { $0.state == .dispatching } }
    var needsReview: [MailScheduleEntry] { entries.filter { $0.state == .needsReview } }
    var submitted: [MailScheduleEntry] { entries.filter { $0.state == .submitted } }
    var visible: [MailScheduleEntry] { entries.filter { $0.state != .cancelled } }

    func start() {
        guard timer == nil, !persistenceBlocked else { return }
        timerGeneration &+= 1
        let generation = timerGeneration
        timer = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.timerGeneration == generation { self.timer = nil }
            }
            while !Task.isCancelled {
                guard !self.persistenceBlocked else { return }
                if let active = self.dispatchWork.values.first {
                    await active.value
                    continue
                }
                guard let next = self.scheduled.min(by: { $0.scheduledAt < $1.scheduledAt }) else {
                    do { try await self.clock.sleep(until: self.clock.now().addingTimeInterval(60)) }
                    catch { return }
                    continue
                }
                do { try await self.clock.sleep(until: next.scheduledAt) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self.runDispatch(next.id)
            }
        }
    }

    func stop() {
        timerGeneration &+= 1
        timer?.cancel(); timer = nil
    }

    /// The app can await this during its existing mail-shutdown path. Cancelling the timer does
    /// not cancel a transport handoff that already passed its durable dispatch checkpoint.
    func waitForDispatches() async {
        while true {
            let active = Array(dispatchWork.values)
            guard !active.isEmpty else { return }
            for work in active { await work.value }
        }
    }

    /// Persists the complete draft, including its source and attachment bytes, before the
    /// composer is allowed to close. A failed save leaves the caller's draft untouched.
    @discardableResult
    func schedule(_ draft: MailModel.Draft, account: MailAccountIdentity, at date: Date,
                  now: Date? = nil, confirmSentCheck: Bool = false) throws -> MailScheduleEntry {
        try validate(draft, account: account, confirmSentCheck: confirmSentCheck)
        let current = now ?? clock.now()
        guard date > current else { throw MailScheduleError.dateInPast }
        guard !entries.contains(where: { $0.state != .cancelled && $0.draft.id == draft.id }) else {
            throw MailScheduleError.duplicateDraft
        }
        var scheduledDraft = draft
        if confirmSentCheck { scheduledDraft.uncertainSend = false }
        let item = MailScheduleEntry(id: UUID(), account: account, draft: scheduledDraft, createdAt: current,
                                     scheduledAt: date, state: .scheduled, note: nil, lastAttemptAt: nil)
        try commit(entries + [item])
        poke()
        return item
    }

    /// Explicit user edit. Editing is the only way a needs-review item can return to the
    /// scheduled state, which prevents automatic catch-up or resend after a restart.
    @discardableResult
    func edit(_ id: UUID, draft: MailModel.Draft, account: MailAccountIdentity, at date: Date,
              now: Date? = nil, confirmSentCheck: Bool = false) throws -> MailScheduleEntry {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MailScheduleError.notFound }
        guard [.scheduled, .needsReview].contains(entries[index].state) else { throw MailScheduleError.cannotEdit }
        guard !entries[index].requiresSentCheck || confirmSentCheck else {
            throw MailScheduleError.sentCheckRequired
        }
        try validate(draft, account: account, confirmSentCheck: confirmSentCheck)
        guard date > (now ?? clock.now()) else { throw MailScheduleError.dateInPast }
        var next = entries
        var item = next[index]
        var scheduledDraft = draft
        if confirmSentCheck { scheduledDraft.uncertainSend = false }
        item.draft = scheduledDraft
        item.account = account
        item.scheduledAt = date
        item.state = .scheduled
        item.note = nil
        item.lastAttemptAt = nil
        next[index] = item
        try commit(next)
        poke()
        return item
    }

    func cancel(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MailScheduleError.notFound }
        guard entries[index].state != .dispatching else { throw MailScheduleError.cannotCancelInFlight }
        var next = entries
        next[index].state = .cancelled
        next[index].note = "Cancelled on this Mac."
        try commit(next)
        poke()
    }

    /// A reconnect or account edit never drops a scheduled snapshot. It changes active items to
    /// needsReview, where the user must explicitly edit or reschedule before any send occurs.
    func reconcile(accounts: [MailAccountIdentity]) throws {
        let available = Set(accounts)
        var next = entries
        var changed = false
        for index in next.indices where [.scheduled, .needsReview].contains(next[index].state) {
            guard available.contains(next[index].account),
                  next[index].draft.fromAccountID == next[index].account.accountID,
                  next[index].draft.fromAddress == next[index].account.address else {
                next[index].state = .needsReview
                next[index].note = MailScheduleError.unavailableAccount.localizedDescription
                changed = true
                continue
            }
        }
        if changed { try commit(next); poke() }
    }

    /// The timer calls this only for a due item. It writes `dispatching` before invoking the
    /// injected root submission closure, making duplicate sends impossible across races/relaunch.
    func dispatchNow(_ id: UUID) async {
        await runDispatch(id)
    }

    private func runDispatch(_ id: UUID) async {
        if let active = dispatchWork[id] {
            await active.value
            return
        }
        let work = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            defer { self.dispatchWork.removeValue(forKey: id) }
            await self.dispatchIfDue(id)
        }
        dispatchWork[id] = work
        await work.value
    }

    private func dispatchIfDue(_ id: UUID) async {
        guard !persistenceBlocked,
              dispatchingID == nil,
              let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].state == .scheduled else { return }
        let now = clock.now()
        guard entries[index].scheduledAt <= now else { return }
        if now.timeIntervalSince(entries[index].scheduledAt) > lateTolerance {
            var next = entries
            next[index].state = .needsReview
            next[index].note = "The scheduled time was missed while Jevcast was not running or this Mac was asleep. Review before sending."
            do { try commit(next) } catch { return }
            return
        }

        let item = entries[index]
        guard let submission else {
            var next = entries
            next[index].state = .needsReview
            next[index].note = MailScheduleError.noSubmission.localizedDescription
            do { try commit(next) } catch { return }
            return
        }

        var checkpoint = entries
        checkpoint[index].state = .dispatching
        checkpoint[index].lastAttemptAt = now
        checkpoint[index].note = "Sending…"
        do {
            try commit(checkpoint)
        } catch {
            // The original scheduled snapshot remains in memory and on disk. Never call the
            // transport without a durable dispatch checkpoint.
            return
        }

        dispatchingID = id
        defer { dispatchingID = nil }
        if let accountCheck, !(await accountCheck(item)) {
            guard let currentIndex = entries.firstIndex(where: { $0.id == id }) else { return }
            var next = entries
            next[currentIndex].state = .needsReview
            next[currentIndex].note = MailScheduleError.unavailableAccount.localizedDescription
            do { try commit(next) } catch { return }
            return
        }
        do {
            let result = try await submission(item)
            guard let currentIndex = entries.firstIndex(where: { $0.id == id }) else { return }
            var next = entries
            next[currentIndex].state = .submitted
            next[currentIndex].note = Self.submissionNote(result)
            do { try commit(next) }
            catch {
                // The durable dispatching checkpoint prevents a later launch from resending.
                return
            }
        } catch {
            guard let currentIndex = entries.firstIndex(where: { $0.id == id }) else { return }
            var next = entries
            next[currentIndex].state = .needsReview
            next[currentIndex].note = "The scheduled send needs review: " + error.localizedDescription
            do { try commit(next) } catch { return }
        }
    }

    private func validate(_ draft: MailModel.Draft, account: MailAccountIdentity,
                          confirmSentCheck: Bool) throws {
        guard !account.accountID.isEmpty, !account.address.isEmpty else { throw MailScheduleError.invalidAccount }
        guard draft.backend == MailBackend.jevcast.rawValue else {
            throw MailScheduleError.invalidDraft("Scheduled sending is available only for Jevcast accounts.")
        }
        guard draft.fromAccountID == account.accountID, draft.fromAddress == account.address else {
            throw MailScheduleError.invalidAccount
        }
        guard !draft.uncertainSend || confirmSentCheck else { throw MailScheduleError.sentCheckRequired }
        var sendableDraft = draft
        if confirmSentCheck { sendableDraft.uncertainSend = false }
        if let problem = sendableDraft.sendProblem {
            throw MailScheduleError.invalidDraft(problem)
        }
    }

    private func commit(_ next: [MailScheduleEntry]) throws {
        do {
            try store.save(.init(entries: next))
            entries = next
            persistenceProblem = nil
            persistenceBlocked = false
        } catch {
            let problem = error.localizedDescription
            persistenceProblem = problem
            persistenceBlocked = true
            timerGeneration &+= 1
            timer?.cancel(); timer = nil
            throw MailScheduleError.persistence(problem)
        }
    }

    private func poke() {
        guard timer != nil, !persistenceBlocked else { return }
        timerGeneration &+= 1
        timer?.cancel(); timer = nil
        start()
    }

    private static func normalizedForLaunch(_ entries: [MailScheduleEntry], now: Date) -> (entries: [MailScheduleEntry], changed: Bool) {
        var result = entries
        var changed = false
        for index in result.indices {
            switch result[index].state {
            case .dispatching:
                result[index].state = .needsReview
                result[index].note = "The app stopped during delivery. Check Sent before resending."
                changed = true
            case .scheduled where result[index].scheduledAt <= now:
                result[index].state = .needsReview
                result[index].note = "Jevcast was not running when this message was due. Review before sending."
                changed = true
            default: break
            }
        }
        return (result, changed)
    }

    private static func submissionNote(_ result: MailSubmission) -> String {
        switch result {
        case .appleMailQueued: return "Queued in Apple Mail. Delivery is managed by Apple Mail."
        case .serverAccepted(let receipt): return receipt?.note.map { "Sent. " + $0 } ?? "Sent."
        }
    }
}
