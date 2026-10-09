import Foundation

public struct MailSmartMailbox: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var predicate: MailRulePredicate
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, predicate: MailRulePredicate, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.predicate = predicate; self.createdAt = createdAt
    }

    public func matches(_ message: MailRuleMessage) -> Bool { predicate.matches(message) }
}

public struct MailSmartState: Codable, Equatable, Sendable {
    public var mailboxes: [MailSmartMailbox]
    public var vipAddresses: Set<String>
    public var blockedSenders: Set<String>
    /// Exact rule IDs created by the block-sender action. Older state may not have this map.
    public var blockedRuleIDs: [String: UUID]

    public init(mailboxes: [MailSmartMailbox] = [], vipAddresses: Set<String> = [], blockedSenders: Set<String> = [],
                blockedRuleIDs: [String: UUID] = [:]) {
        self.mailboxes = mailboxes
        self.vipAddresses = vipAddresses
        self.blockedSenders = blockedSenders
        self.blockedRuleIDs = blockedRuleIDs
    }

    private enum CodingKeys: String, CodingKey { case mailboxes, vipAddresses, blockedSenders, blockedRuleIDs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mailboxes = try container.decode([MailSmartMailbox].self, forKey: .mailboxes)
        vipAddresses = try container.decode(Set<String>.self, forKey: .vipAddresses)
        blockedSenders = try container.decode(Set<String>.self, forKey: .blockedSenders)
        blockedRuleIDs = try container.decodeIfPresent([String: UUID].self, forKey: .blockedRuleIDs) ?? [:]
    }
}

/// Saved filters, VIP addresses, and blocked senders live together so the launcher can load one
/// small file at startup. Blocking a sender returns a rule draft; the caller saves it through the
/// normal ordered rule store after choosing the account's current Junk folder.
public final class MailSmartStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jevcast/Mail/smart-mailboxes.json")
    }

    public let url: URL
    public private(set) var loadError: String?
    private var state: MailSmartState
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL = MailSmartStore.defaultURL) {
        self.url = url
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .deferredToDate
        self.encoder = encoder
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .deferredToDate
        self.decoder = decoder
        if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            self.state = MailSmartState(); self.loadError = nil
        } else {
            do {
                guard let data = try SecureFile.read(url, maxBytes: SecureFile.maxJSON) else {
                    self.state = MailSmartState(); self.loadError = nil
                    return
                }
                try MailRulesSecureState.validateFile(url)
                let decoded = try decoder.decode(MailSmartState.self, from: data)
                try Self.validate(decoded)
                self.state = decoded
                self.loadError = nil
            } catch {
                self.state = MailSmartState(); self.loadError = error.localizedDescription
            }
        }
    }

    public func load() -> MailSmartState { lock.withLock { state } }

    public func save(_ value: MailSmartState) throws {
        lock.lock(); defer { lock.unlock() }
        try Self.validate(value)
        try validateExisting()
        try persist(value)
        state = value
        loadError = nil
    }

    @discardableResult public func saveMailbox(_ mailbox: MailSmartMailbox) throws -> MailSmartMailbox {
        var value = load()
        guard !mailbox.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailSmartStoreError.invalid("Saved mailboxes need a name.") }
        guard !mailbox.predicate.isEmpty else { throw MailSmartStoreError.invalid("Saved mailboxes need at least one filter.") }
        if let index = value.mailboxes.firstIndex(where: { $0.id == mailbox.id }) { value.mailboxes[index] = mailbox }
        else { value.mailboxes.append(mailbox) }
        try save(value)
        return mailbox
    }

    public func deleteMailbox(id: UUID) throws {
        var value = load(); value.mailboxes.removeAll { $0.id == id }; try save(value)
    }

    public func setVIP(_ address: String, enabled: Bool) throws {
        let value = load()
        let normalized = Self.normalize(address)
        guard !normalized.isEmpty, normalized.contains("@") else { throw MailSmartStoreError.invalid("Enter a complete email address.") }
        var next = value
        if enabled { next.vipAddresses.insert(normalized) } else { next.vipAddresses.remove(normalized) }
        try save(next)
    }

    /// Returns an enabled move rule draft. The caller must supply the currently validated Junk
    /// mailbox identity and save the returned rule through `MailRuleStore`.
    public func blockedSenderRule(_ address: String, accountID: String, junkMailboxID: Int64,
                                  junkPath: String, now: Date = Date()) throws -> MailRule {
        let normalized = Self.normalize(address)
        guard !normalized.isEmpty, normalized.contains("@") else { throw MailSmartStoreError.invalid("Enter a complete sender address.") }
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, junkMailboxID > 0,
              !junkPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailSmartStoreError.invalid("Choose the current account and Junk folder.")
        }
        return MailRule(name: "Block \(normalized)", predicate: MailRulePredicate(from: normalized),
                        actions: [.moveToFolder(accountID: accountID, mailboxID: junkMailboxID, path: junkPath)], updatedAt: now)
    }

    public func addBlockedSender(_ address: String, ruleID: UUID? = nil) throws {
        let normalized = Self.normalize(address)
        guard !normalized.isEmpty, normalized.contains("@") else { throw MailSmartStoreError.invalid("Enter a complete sender address.") }
        var next = load(); next.blockedSenders.insert(normalized)
        if let ruleID { next.blockedRuleIDs[normalized] = ruleID }
        try save(next)
    }

    public func removeBlockedSender(_ address: String) throws {
        let normalized = Self.normalize(address)
        guard !normalized.isEmpty else { throw MailSmartStoreError.invalid("Enter a complete sender address.") }
        var next = load()
        next.blockedSenders.remove(normalized)
        next.blockedRuleIDs[normalized] = nil
        try save(next)
    }

    @discardableResult public func blockSender(_ address: String, accountID: String, junkMailboxID: Int64,
                                               junkPath: String, now: Date = Date()) throws -> MailRule {
        let rule = try blockedSenderRule(address, accountID: accountID, junkMailboxID: junkMailboxID, junkPath: junkPath, now: now)
        try addBlockedSender(address, ruleID: rule.id)
        return rule
    }

    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func persist(_ value: MailSmartState) throws {
        try SecureFile.ensureParents(of: url)
        try SecureFile.write(try encoder.encode(value), to: url)
    }

    private func validateExisting() throws {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return }
        do {
            guard let data = try SecureFile.read(url, maxBytes: SecureFile.maxJSON) else { return }
            try MailRulesSecureState.validateFile(url)
            try Self.validate(try decoder.decode(MailSmartState.self, from: data))
        } catch {
            loadError = error.localizedDescription
            throw MailSmartStoreError.invalid(error.localizedDescription)
        }
    }

    private static func validate(_ value: MailSmartState) throws {
        guard Set(value.mailboxes.map(\.id)).count == value.mailboxes.count else { throw MailSmartStoreError.invalid("Saved mailbox IDs must be unique.") }
        for mailbox in value.mailboxes {
            guard !mailbox.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !mailbox.predicate.isEmpty else {
                throw MailSmartStoreError.invalid("Saved mailboxes need a name and one filter.")
            }
        }
        guard value.vipAddresses.allSatisfy({ $0.contains("@") }), value.blockedSenders.allSatisfy({ $0.contains("@") }) else {
            throw MailSmartStoreError.invalid("Saved address lists contain an invalid address.")
        }
        guard value.blockedRuleIDs.keys.allSatisfy({ value.blockedSenders.contains($0) }) else {
            throw MailSmartStoreError.invalid("Saved block rules do not match the blocked sender list.")
        }
    }
}

public enum MailSmartStoreError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
