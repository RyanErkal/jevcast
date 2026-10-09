import Combine
import Foundation
import LauncherCore

protocol MailScheduleClock: AnyObject, Sendable {
    func now() -> Date
    func sleep(until date: Date) async throws
}

final class MailSystemClock: MailScheduleClock, @unchecked Sendable {
    func now() -> Date { Date() }

    func sleep(until date: Date) async throws {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 365 * 24 * 60 * 60) * 1_000_000_000))
    }
}

/// A deterministic clock for local subsystem tests. Advancing the clock wakes only sleeps whose
/// deadline has been reached. It never reads or changes the Mac clock.
final class MailManualClock: MailScheduleClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var value: Date
    private var waiters: [UUID: Waiter] = [:]
    private(set) var sleepCount = 0

    init(now: Date) { value = now }

    func now() -> Date { lock.withLock { value } }

    func sleep(until date: Date) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow = lock.withLock { () -> Bool in
                    sleepCount += 1
                    if value >= date { return true }
                    waiters[id] = Waiter(deadline: date, continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
                if Task.isCancelled { cancel(id) }
            }
        }, onCancel: { [weak self] in
            self?.cancel(id)
        })
    }

    func advance(by interval: TimeInterval) { advance(to: now().addingTimeInterval(interval)) }

    func advance(to date: Date) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            value = max(value, date)
            let ids = waiters.compactMap { $0.value.deadline <= value ? $0.key : nil }
            return ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        ready.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { waiters.removeValue(forKey: id)?.continuation }
        continuation?.resume(throwing: CancellationError())
    }
}

enum MailSnoozeError: LocalizedError, Equatable {
    case invalidMessageIdentity
    case duplicateMessage
    case dateInPast
    case accountChanged
    case notFound
    case notReady
    case cannotCancelInFlight
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidMessageIdentity: return "This message has no stable account and message identity."
        case .duplicateMessage: return "This message is already snoozed."
        case .dateInPast: return "Choose a future time."
        case .accountChanged: return "This account changed or is disconnected. Review the message before using it."
        case .notFound: return "The snoozed message is no longer available."
        case .notReady: return "This message is not ready to return yet."
        case .cannotCancelInFlight: return "This delayed action is already being handed off. Review it after the handoff finishes."
        case .persistence(let message): return message
        }
    }
}

/// Local, per-message snooze state. It never moves a provider message to a server folder. The
/// root launcher can use `ready` to put a message back in its visible list at the due time.
@MainActor
final class MailSnoozeCenter: ObservableObject {
    @Published private(set) var entries: [MailSnoozeEntry] = []
    @Published private(set) var persistenceProblem: String?

    let store: MailSnoozeStore
    let clock: any MailScheduleClock
    private let lateTolerance: TimeInterval
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    private var persistenceBlocked = false

    init(store: MailSnoozeStore = .standard, clock: any MailScheduleClock = MailSystemClock(),
         lateTolerance: TimeInterval = 2, automaticallyStart: Bool = false) {
        self.store = store
        self.clock = clock
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

    var snoozed: [MailSnoozeEntry] { entries.filter { $0.state == .scheduled } }
    var ready: [MailSnoozeEntry] { entries.filter { $0.state == .ready } }
    var needsReview: [MailSnoozeEntry] { entries.filter { $0.state == .needsReview } }
    var visible: [MailSnoozeEntry] { entries }

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
                guard let next = self.snoozed.min(by: { $0.scheduledAt < $1.scheduledAt }) else {
                    do { try await self.clock.sleep(until: self.clock.now().addingTimeInterval(60)) }
                    catch { return }
                    continue
                }
                do { try await self.clock.sleep(until: next.scheduledAt) }
                catch { return }
                guard !Task.isCancelled else { return }
                self.processDue(next.id)
            }
        }
    }

    func stop() {
        timerGeneration &+= 1
        timer?.cancel()
        timer = nil
    }

    /// Adds one local snooze. The summary is copied before this call returns, so later sync
    /// changes cannot make the visible snooze refer to another row.
    @discardableResult
    func snooze(message: MailSummary, account: MailAccountIdentity, messageID: String? = nil,
                until date: Date, now: Date? = nil) throws -> MailSnoozeEntry {
        guard !account.accountID.isEmpty, !account.address.isEmpty, !message.messageKey.isEmpty,
              (!message.messageKey.hasPrefix("row:") || messageID?.isEmpty == false) else {
            throw MailSnoozeError.invalidMessageIdentity
        }
        let current = now ?? clock.now()
        guard date > current else { throw MailSnoozeError.dateInPast }
        let identity = MailMessageIdentity(account: account, messageKey: message.messageKey, messageID: messageID)
        guard !entries.contains(where: { $0.identity == identity }) else {
            throw MailSnoozeError.duplicateMessage
        }
        let item = MailSnoozeEntry(identity: identity, account: account, summary: message,
                                   createdAt: current, scheduledAt: date, state: .scheduled, note: nil)
        try commit(entries + [item])
        poke()
        return item
    }

    func cancel(_ id: MailMessageIdentity) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MailSnoozeError.notFound }
        var next = entries
        next.remove(at: index)
        try commit(next)
        poke()
    }

    /// Returns a ready item to the caller and removes the local snooze only after the durable
    /// removal succeeds. The caller can then refresh its visible message list.
    @discardableResult
    func consumeReady(_ id: MailMessageIdentity) throws -> MailSnoozeEntry {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MailSnoozeError.notFound }
        guard entries[index].state == .ready else { throw MailSnoozeError.notReady }
        let item = entries[index]
        var next = entries; next.remove(at: index)
        try commit(next)
        return item
    }

    func reschedule(_ id: MailMessageIdentity, until date: Date, now: Date? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MailSnoozeError.notFound }
        guard date > (now ?? clock.now()) else { throw MailSnoozeError.dateInPast }
        var next = entries
        next[index].scheduledAt = date
        next[index].state = .scheduled
        next[index].note = nil
        try commit(next)
        poke()
    }

    /// Disconnects or identity changes never delete a snooze. They make it a review item so the
    /// user can choose what to do after reconnecting.
    func reconcile(accounts: [MailAccountIdentity]) throws {
        let available = Set(accounts)
        var next = entries
        var changed = false
        for index in next.indices where next[index].state == .scheduled || next[index].state == .ready {
            guard available.contains(next[index].account) else {
                next[index].state = .needsReview
                next[index].note = MailSnoozeError.accountChanged.localizedDescription
                changed = true
                continue
            }
        }
        if changed { try commit(next); poke() }
    }

    private func processDue(_ id: MailMessageIdentity) {
        guard !persistenceBlocked else { return }
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state == .scheduled else { return }
        let late = clock.now().timeIntervalSince(entries[index].scheduledAt)
        var next = entries
        if late > lateTolerance {
            next[index].state = .needsReview
            next[index].note = "The snooze was missed while this Mac was asleep. Review before returning it."
        } else {
            next[index].state = .ready
            next[index].note = nil
        }
        do { try commit(next) } catch { return }
    }

    private func commit(_ next: [MailSnoozeEntry]) throws {
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
            throw MailSnoozeError.persistence(problem)
        }
    }

    private func poke() {
        guard timer != nil, !persistenceBlocked else { return }
        timerGeneration &+= 1
        timer?.cancel(); timer = nil
        start()
    }

    private static func normalizedForLaunch(_ entries: [MailSnoozeEntry], now: Date) -> (entries: [MailSnoozeEntry], changed: Bool) {
        var result = entries
        var changed = false
        for index in result.indices where result[index].state == .scheduled && result[index].scheduledAt <= now {
            result[index].state = .needsReview
            result[index].note = "Jevcast was not running when this snooze became due. Review before returning it."
            changed = true
        }
        return (result, changed)
    }
}
