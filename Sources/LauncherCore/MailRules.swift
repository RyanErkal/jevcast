import Foundation

/// The small, provider-neutral view of a message that rules need.
///
/// The identity must remain stable for the lifetime of a message. For the native store,
/// use the account ID, mailbox ID, and row ID (or a Message-ID when the caller has one).
public struct MailRuleMessage: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let accountID: String
    public let mailboxID: Int64
    public let mailboxPath: String
    public let from: String
    public let to: [String]
    public let subject: String
    public let receivedAt: Date
    public var isRead: Bool
    public var isFlagged: Bool

    public init(id: String, accountID: String, mailboxID: Int64, mailboxPath: String,
                from: String, to: [String] = [], subject: String, receivedAt: Date,
                isRead: Bool, isFlagged: Bool) {
        self.id = id
        self.accountID = accountID
        self.mailboxID = mailboxID
        self.mailboxPath = mailboxPath
        self.from = from
        self.to = to
        self.subject = subject
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.isFlagged = isFlagged
    }
}

public extension MailRuleMessage {
    /// A stable ID for a row in the native store. The caller can use a stronger Message-ID when
    /// it has one, but must not use a list index or a transient object identity.
    static func nativeID(accountID: String, mailboxID: Int64, rowID: Int64) -> String {
        "native:\(accountID):\(mailboxID):\(rowID)"
    }

    var normalizedFrom: String { Self.normalized(from) }
    var normalizedRecipients: [String] { to.map(Self.normalized) }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The fields a rule can inspect. Empty fields mean "any".
public struct MailRulePredicate: Codable, Equatable, Hashable, Sendable {
    public var from: String?
    public var to: String?
    public var subject: String?
    public var accountID: String?

    public init(from: String? = nil, to: String? = nil, subject: String? = nil, accountID: String? = nil) {
        self.from = from
        self.to = to
        self.subject = subject
        self.accountID = accountID
    }

    public func matches(_ message: MailRuleMessage) -> Bool {
        func contains(_ value: String, _ query: String?) -> Bool {
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            return value.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard contains(message.from, from), contains(message.subject, subject) else { return false }
        if let accountID, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard message.accountID == accountID.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        }
        guard let to, !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return message.to.contains { contains($0, to) }
    }

    public var isEmpty: Bool {
        [from, to, subject, accountID].allSatisfy { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
    }
}

/// The only actions a rule may execute. There is intentionally no send or permanent-delete case.
public enum MailRuleAction: Codable, Equatable, Hashable, Sendable {
    case markRead(Bool)
    case markFlagged(Bool)
    /// `mailboxID` is revalidated by the injected executor immediately before the change.
    case moveToFolder(accountID: String, mailboxID: Int64, path: String)

    public var stableID: String {
        switch self {
        case .markRead(let value): return "read:\(value)"
        case .markFlagged(let value): return "flagged:\(value)"
        case let .moveToFolder(accountID, mailboxID, path): return "move:\(accountID):\(mailboxID):\(path)"
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, value, accountID, mailboxID, path }
    private enum Kind: String, Codable { case markRead, markFlagged, moveToFolder }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .markRead: self = .markRead(try container.decode(Bool.self, forKey: .value))
        case .markFlagged: self = .markFlagged(try container.decode(Bool.self, forKey: .value))
        case .moveToFolder:
            self = .moveToFolder(accountID: try container.decode(String.self, forKey: .accountID),
                                 mailboxID: try container.decode(Int64.self, forKey: .mailboxID),
                                 path: try container.decode(String.self, forKey: .path))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .markRead(let value):
            try container.encode(Kind.markRead, forKey: .kind); try container.encode(value, forKey: .value)
        case .markFlagged(let value):
            try container.encode(Kind.markFlagged, forKey: .kind); try container.encode(value, forKey: .value)
        case let .moveToFolder(accountID, mailboxID, path):
            try container.encode(Kind.moveToFolder, forKey: .kind)
            try container.encode(accountID, forKey: .accountID)
            try container.encode(mailboxID, forKey: .mailboxID)
            try container.encode(path, forKey: .path)
        }
    }
}

public struct MailRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let formatVersion = 1
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var predicate: MailRulePredicate
    public var actions: [MailRuleAction]
    public var order: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, enabled: Bool = true,
                predicate: MailRulePredicate = MailRulePredicate(), actions: [MailRuleAction],
                order: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.predicate = predicate
        self.actions = actions
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var revision: String { "\(id.uuidString):\(updatedAt.timeIntervalSinceReferenceDate)" }
}

public struct MailRulePreview: Equatable, Sendable {
    public let ruleID: UUID
    public let messageIDs: [String]
    public let messages: [MailRuleMessage]

    public init(ruleID: UUID, messages: [MailRuleMessage]) {
        self.ruleID = ruleID
        self.messages = messages
        self.messageIDs = messages.map(\.id)
    }
    public var count: Int { messages.count }
}

public enum MailRuleApplicationState: String, Codable, Equatable, Sendable {
    case running
    case applied
    case failed
    case needsReview
}

public struct MailRuleApplication: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let ruleID: UUID
    public let ruleRevision: String
    public let messageID: String
    public let actionID: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: MailRuleApplicationState
    public var error: String?

    public init(rule: MailRule, messageID: String, action: MailRuleAction, now: Date = Date()) {
        self.ruleID = rule.id
        self.ruleRevision = rule.revision
        self.messageID = messageID
        self.actionID = action.stableID
        self.id = Self.makeID(ruleID: rule.id, revision: rule.revision, messageID: messageID, actionID: action.stableID)
        self.startedAt = now
        self.finishedAt = nil
        self.state = .running
        self.error = nil
    }

    public static func makeID(ruleID: UUID, revision: String, messageID: String, actionID: String) -> String {
        [ruleID.uuidString, revision, messageID, actionID].joined(separator: "|")
    }
}

public enum MailRuleExecutionError: Error, LocalizedError, Equatable, Sendable {
    case needsReview(String)

    public var errorDescription: String? {
        switch self { case .needsReview(let message): return message }
    }
}

public struct MailRuleApplyResult: Equatable, Sendable {
    public var applied: [String] = []
    public var skipped: [String] = []
    public var failed: [String] = []
    public var needsReview: [String] = []
    public init() {}
}

public enum MailRuleStoreError: Error, LocalizedError, Equatable {
    case invalidRule(String)
    case invalidFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRule(let message), .invalidFile(let message): return message
        }
    }
}

/// A small, owner-only JSON store for ordered rules and their application receipts.
public final class MailRuleStore: @unchecked Sendable {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jevcast/Mail", isDirectory: true)
    }

    public let root: URL
    public let rulesURL: URL
    public let applicationsURL: URL
    public private(set) var rulesError: String?
    public private(set) var applicationsError: String?
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL = MailRuleStore.defaultRoot) {
        self.root = root
        self.rulesURL = root.appendingPathComponent("rules.json")
        self.applicationsURL = root.appendingPathComponent("rule-applications.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        self.decoder = decoder
        self.rulesError = nil
        self.applicationsError = nil
    }

    public func loadRules() -> [MailRule] {
        locked {
            do {
                guard let data = try readIfPresent(rulesURL) else { rulesError = nil; return [] }
                let decoded = try decoder.decode([MailRule].self, from: data)
                try validateRules(decoded)
                rulesError = nil
                return decoded.sorted {
                    if $0.order != $1.order { return $0.order < $1.order }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            } catch {
                rulesError = error.localizedDescription
                return []
            }
        }
    }

    public func saveRules(_ rules: [MailRule]) throws {
        try locked {
            try validateExisting(rulesURL, decode: [MailRule].self, validate: { try self.validateRules($0) })
            try validateRules(rules)
            try write(rules.sorted { $0.order < $1.order }, to: rulesURL)
            rulesError = nil
        }
    }

    public func saveRule(_ rule: MailRule) throws {
        var rules = loadRules()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        try saveRules(reindexed(rules))
    }

    public func deleteRule(id: UUID) throws {
        try saveRules(reindexed(loadRules().filter { $0.id != id }))
    }

    public func moveRule(id: UUID, to index: Int) throws {
        var rules = loadRules()
        if let rulesError { throw MailRuleStoreError.invalidFile(rulesError) }
        guard let old = rules.firstIndex(where: { $0.id == id }) else { return }
        let rule = rules.remove(at: old)
        rules.insert(rule, at: min(max(index, 0), rules.count))
        try saveRules(reindexed(rules))
    }

    public func loadApplications() -> [String: MailRuleApplication] {
        locked {
            do {
                guard let data = try readIfPresent(applicationsURL) else { applicationsError = nil; return [:] }
                let decoded = try decoder.decode([String: MailRuleApplication].self, from: data)
                try validateApplications(decoded)
                applicationsError = nil
                return decoded
            } catch {
                applicationsError = error.localizedDescription
                return [:]
            }
        }
    }

    public func saveApplications(_ applications: [String: MailRuleApplication]) throws {
        try locked {
            try validateExisting(applicationsURL, decode: [String: MailRuleApplication].self,
                                 validate: { try self.validateApplications($0) })
            try write(applications, to: applicationsURL)
            applicationsError = nil
        }
    }

    /// A crashed application never gets replayed automatically. It needs a user review.
    @discardableResult public func recoverRunningApplications(now: Date = Date()) throws -> Int {
        var applications = loadApplications()
        if let applicationsError { throw MailRuleStoreError.invalidFile(applicationsError) }
        var recovered = 0
        for key in applications.keys where applications[key]?.state == .running {
            applications[key]?.state = .needsReview
            applications[key]?.finishedAt = now
            applications[key]?.error = "The previous rule run stopped before it was confirmed. Review this message before trying again."
            recovered += 1
        }
        if recovered > 0 { try saveApplications(applications) }
        return recovered
    }

    private func reindexed(_ rules: [MailRule]) -> [MailRule] {
        rules.enumerated().map { index, rule in
            var value = rule; value.order = index; return value
        }
    }

    private func validateRules(_ rules: [MailRule]) throws {
        guard Set(rules.map(\.id)).count == rules.count else { throw MailRuleStoreError.invalidRule("Rule IDs must be unique.") }
        guard rules.allSatisfy({ $0.order >= 0 }) else {
            throw MailRuleStoreError.invalidRule("Rule order values must be non-negative.")
        }
        for rule in rules {
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailRuleStoreError.invalidRule("Rules need a name.") }
            guard !rule.actions.isEmpty else { throw MailRuleStoreError.invalidRule("A rule needs at least one action.") }
            guard !rule.predicate.isEmpty else { throw MailRuleStoreError.invalidRule("A rule needs at least one condition.") }
            for action in rule.actions {
                if case let .moveToFolder(accountID, mailboxID, path) = action,
                   accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mailboxID <= 0 || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw MailRuleStoreError.invalidRule("A move action needs a current account and folder.")
                }
            }
        }
    }

    private func validateApplications(_ applications: [String: MailRuleApplication]) throws {
        guard applications.allSatisfy({ entry in !entry.key.isEmpty && entry.key == entry.value.id }) else {
            throw MailRuleStoreError.invalidFile("Rule application history contains an invalid receipt.")
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try SecureFile.ensureParents(of: url)
        try SecureFile.ensureDirectory(root)
        let data = try encoder.encode(value)
        try SecureFile.write(data, to: url)
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        try SecureFile.ensureDirectory(root)
        guard let data = try SecureFile.read(url, maxBytes: SecureFile.maxJSON) else { return nil }
        try MailRulesSecureState.validateFile(url)
        return data
    }

    private func validateExisting<T: Decodable>(_ url: URL, decode type: T.Type, validate: ((T) throws -> Void)? = nil) throws {
        do {
            guard let data = try readIfPresent(url) else { return }
            let value = try decoder.decode(type, from: data)
            try validate?(value)
        } catch {
            if url == rulesURL { rulesError = error.localizedDescription }
            else { applicationsError = error.localizedDescription }
            throw MailRuleStoreError.invalidFile(error.localizedDescription)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

/// Applies matching rules through an injected native action boundary.
public final class MailRuleEngine: @unchecked Sendable {
    public typealias ActionExecutor = @Sendable (MailRuleAction, MailRuleMessage) async throws -> Void

    private let store: MailRuleStore
    private let execute: ActionExecutor
    private let lock = NSLock()

    public init(store: MailRuleStore, execute: @escaping ActionExecutor) {
        self.store = store
        self.execute = execute
    }

    public func preview(rule: MailRule, messages: [MailRuleMessage]) -> MailRulePreview {
        MailRulePreview(ruleID: rule.id, messages: messages.filter { rule.enabled && rule.predicate.matches($0) })
    }

    /// Applies only the supplied observations. It never loads or mutates an entire mailbox on its own.
    public func apply(rule: MailRule, messages: [MailRuleMessage], now: Date = Date()) async -> MailRuleApplyResult {
        guard rule.enabled else { return MailRuleApplyResult() }
        let matches = preview(rule: rule, messages: messages).messages
        return await apply(rule: rule, matches: matches, now: now)
    }

    /// `matches` is normally the result of an explicit preview. This is the only API that executes
    /// existing messages, which keeps retroactive changes user-confirmed.
    public func apply(rule: MailRule, matches: [MailRuleMessage], now: Date = Date()) async -> MailRuleApplyResult {
        var result = MailRuleApplyResult()
        for message in matches {
            for action in rule.actions {
                let application = MailRuleApplication(rule: rule, messageID: message.id, action: action, now: now)
                let shouldRun = lock.withLock {
                    var applications = store.loadApplications()
                    guard applications[application.id] == nil else {
                        result.skipped.append(application.id)
                        return false
                    }
                    applications[application.id] = application
                    do { try store.saveApplications(applications) } catch {
                        result.failed.append(application.id)
                        return false
                    }
                    return true
                }
                guard shouldRun else { continue }
                do {
                    try await execute(action, message)
                    try finish(application.id, state: .applied, error: nil, now: now)
                    result.applied.append(application.id)
                } catch let error as MailRuleExecutionError {
                    try? finish(application.id, state: .needsReview, error: error.localizedDescription, now: now)
                    result.needsReview.append(application.id)
                } catch {
                    try? finish(application.id, state: .failed, error: error.localizedDescription, now: now)
                    result.failed.append(application.id)
                }
            }
        }
        return result
    }

    private func finish(_ id: String, state: MailRuleApplicationState, error: String?, now: Date) throws {
        var applications = store.loadApplications()
        guard var application = applications[id] else { return }
        application.state = state
        application.error = error
        application.finishedAt = now
        applications[id] = application
        try store.saveApplications(applications)
    }
}
