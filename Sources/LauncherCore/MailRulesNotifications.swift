import Foundation

public struct MailNotificationMessage: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let accountID: String
    public let sender: String
    public let subject: String
    public let receivedAt: Date
    public let isRead: Bool

    public init(id: String, accountID: String, sender: String, subject: String, receivedAt: Date, isRead: Bool) {
        self.id = id; self.accountID = accountID; self.sender = sender; self.subject = subject
        self.receivedAt = receivedAt; self.isRead = isRead
    }
}

public struct MailNotificationSettings: Codable, Equatable, Sendable {
    public var enabledAccounts: Set<String>
    public var privatePreviews: Bool
    public var quietStartMinute: Int?
    public var quietEndMinute: Int?

    public init(enabledAccounts: Set<String> = [], privatePreviews: Bool = true,
                quietStartMinute: Int? = nil, quietEndMinute: Int? = nil) {
        self.enabledAccounts = enabledAccounts
        self.privatePreviews = privatePreviews
        self.quietStartMinute = quietStartMinute
        self.quietEndMinute = quietEndMinute
    }

    public func validates() -> Bool {
        func valid(_ minute: Int?) -> Bool { minute == nil || (0..<24 * 60).contains(minute!) }
        return valid(quietStartMinute) && valid(quietEndMinute) && ((quietStartMinute == nil) == (quietEndMinute == nil))
    }

    public func quietHoursContain(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let start = quietStartMinute, let end = quietEndMinute else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if start == end { return true }
        if start < end { return (start..<end).contains(minute) }
        return minute >= start || minute < end
    }
}

public enum MailNotificationSuppression: Equatable, Sendable {
    case disabledAccount
    case quietHours
    case initialHistory
    case duplicate
    case oldHistory
    case persistenceFailure
}

public enum MailNotificationStoreError: Error, LocalizedError, Equatable, Sendable {
    case unreadable(String)
    public var errorDescription: String? {
        if case .unreadable(let message) = self { return message }
        return nil
    }
}

public struct MailNotificationNotice: Equatable, Sendable, Identifiable {
    public let id: String
    public let accountID: String
    public let title: String
    public let message: String
    public let source: MailNotificationMessage

    public init(source: MailNotificationMessage, privatePreview: Bool) {
        id = source.id
        accountID = source.accountID
        self.source = source
        if privatePreview {
            title = "New mail"
            message = "A new message arrived"
        } else {
            title = source.sender.isEmpty ? "New mail" : source.sender
            message = source.subject.isEmpty ? "New message" : source.subject
        }
    }
}

public enum MailNotificationDecision: Equatable, Sendable {
    case deliver(MailNotificationNotice)
    case suppress(MailNotificationSuppression)
}

/// Persisted notification history. It records observations before delivery so a retry after a
/// crash cannot flood the user or repeat the same notice.
public final class MailNotificationLedger: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jevcast/Mail/mail-notifications.json")
    }

    public struct AccountBaseline: Codable, Equatable, Sendable {
        public var establishedAt: Date
        public var messageIDs: Set<String>
        public init(establishedAt: Date, messageIDs: Set<String>) { self.establishedAt = establishedAt; self.messageIDs = messageIDs }
    }

    private struct State: Codable, Equatable, Sendable {
        var baselines: [String: AccountBaseline] = [:]
        var seen: [String: Set<String>] = [:]
    }

    public let url: URL
    public private(set) var loadError: String?
    public private(set) var persistenceError: String?
    private var state: State
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .deferredToDate
        self.encoder = encoder
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .deferredToDate
        self.decoder = decoder
        self.loadError = nil
        self.persistenceError = nil
        if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            self.state = State()
        } else {
            do {
                guard let data = try SecureFile.read(url, maxBytes: SecureFile.maxJSON) else {
                    self.state = State()
                    return
                }
                try MailRulesSecureState.validateFile(url)
                let decoded = try decoder.decode(State.self, from: data)
                try Self.validate(decoded)
                self.state = decoded
            } catch {
                self.state = State()
                self.loadError = error.localizedDescription
            }
        }
    }

    /// The first observation for an account is always a baseline. Pass `initialLoad` for the first
    /// sync or for a history download, even when the store already has another account baseline.
    public func decide(_ message: MailNotificationMessage, settings: MailNotificationSettings,
                       now: Date = Date(), initialLoad: Bool = false, calendar: Calendar = .current) -> MailNotificationDecision {
        lock.lock(); defer { lock.unlock() }
        guard loadError == nil else { return .suppress(.persistenceFailure) }
        guard settings.enabledAccounts.contains(message.accountID) else { return .suppress(.disabledAccount) }
        if initialLoad || state.baselines[message.accountID] == nil {
            establishBaselineLocked(accountID: message.accountID, messages: [message], at: now)
            guard persistLocked() else { return .suppress(.persistenceFailure) }
            return .suppress(.initialHistory)
        }
        if state.seen[message.accountID, default: []].contains(message.id) { return .suppress(.duplicate) }
        state.seen[message.accountID, default: []].insert(message.id)
        let baseline = state.baselines[message.accountID]!
        let decision: MailNotificationDecision
        if message.receivedAt < baseline.establishedAt {
            decision = .suppress(.oldHistory)
        } else if settings.quietHoursContain(now, calendar: calendar) {
            decision = .suppress(.quietHours)
        } else {
            decision = .deliver(MailNotificationNotice(source: message, privatePreview: settings.privatePreviews))
        }
        guard persistLocked() else { return .suppress(.persistenceFailure) }
        return decision
    }

    /// Baselines a complete fetched batch in one write. This is useful when history loads in pages.
    @discardableResult public func establishBaseline(accountID: String, messages: [MailNotificationMessage], at date: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        establishBaselineLocked(accountID: accountID, messages: messages, at: date)
        return persistLocked()
    }

    public func reset(accountID: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let accountID {
            state.baselines[accountID] = nil
            state.seen[accountID] = nil
        } else { state = State() }
        persistLocked()
    }

    private func establishBaselineLocked(accountID: String, messages: [MailNotificationMessage], at date: Date) {
        state.baselines[accountID] = AccountBaseline(establishedAt: date, messageIDs: Set(messages.map(\.id)))
        state.seen[accountID, default: []].formUnion(messages.map(\.id))
    }

    private func persistLocked() -> Bool {
        do {
            guard loadError == nil else { throw MailNotificationStoreError.unreadable(loadError ?? "The notification history could not be read.") }
            if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                if let existing = try SecureFile.read(url, maxBytes: SecureFile.maxJSON) {
                    try MailRulesSecureState.validateFile(url)
                    try Self.validate(decoder.decode(State.self, from: existing))
                }
            }
            try SecureFile.ensureParents(of: url)
            try SecureFile.write(try encoder.encode(state), to: url)
            persistenceError = nil
            return true
        } catch {
            // A notice failure must not make mail sync fail. Crucially, callers do not emit a
            // notch alert until this write succeeds.
            persistenceError = error.localizedDescription
            return false
        }
    }

    private static func validate(_ state: State) throws {
        let validBaseline = state.baselines.allSatisfy { account, baseline in
            !account.isEmpty && baseline.messageIDs.allSatisfy { !$0.isEmpty }
        }
        let validSeen = state.seen.allSatisfy { account, IDs in
            !account.isEmpty && IDs.allSatisfy { !$0.isEmpty }
        }
        guard validBaseline && validSeen else {
            throw MailNotificationStoreError.unreadable("Saved notification history contains an invalid identity.")
        }
    }
}
