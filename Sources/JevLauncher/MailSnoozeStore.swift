import Foundation
import LauncherCore

/// The account and address that a local mail action was created for. This contains no
/// credentials. Both the account ID and address are checked before a delayed action runs.
struct MailAccountIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    let accountID: String
    let address: String

    init(accountID: String, address: String) {
        self.accountID = accountID
        self.address = address
    }

    init(_ sender: MailSendingIdentity) {
        self.init(accountID: sender.accountID, address: sender.address)
    }

    init(_ account: NativeMailAccount) {
        self.init(accountID: account.id, address: account.email)
    }

    var id: String { accountID + ":" + address.lowercased() }
    var fingerprint: String { id }
}

typealias MailSnoozeAccountIdentity = MailAccountIdentity
typealias MailScheduleAccountIdentity = MailAccountIdentity

/// A stable message key. `MailSummary.rowID` is deliberately not used because it is a
/// local database row and can change after a mailbox rebuild.
struct MailMessageIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    let accountID: String
    let messageKey: String
    let messageID: String?

    init(accountID: String, messageKey: String, messageID: String? = nil) {
        self.accountID = accountID
        self.messageKey = messageKey
        self.messageID = messageID
    }

    init(account: MailAccountIdentity, messageKey: String, messageID: String? = nil) {
        self.init(accountID: account.accountID, messageKey: messageKey, messageID: messageID)
    }

    var id: String {
        [accountID, messageKey, messageID ?? ""].joined(separator: "|")
    }
}

enum MailSnoozeState: String, Codable, Sendable {
    case scheduled
    case ready
    case needsReview
}

/// A local-only snooze. The summary is retained for the launcher list, while the identity is
/// retained to avoid confusing the same provider message in two accounts.
struct MailSnoozeEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    let identity: MailMessageIdentity
    let account: MailAccountIdentity
    let summary: MailSummary
    let createdAt: Date
    var scheduledAt: Date
    var state: MailSnoozeState
    var note: String?

    var id: MailMessageIdentity { identity }
}

struct MailSnoozeStoreSnapshot: Codable, Sendable {
    var entries: [MailSnoozeEntry] = []
}

/// A small owner-only, atomic Codable file store used by local mail features.
///
/// It is intentionally separate from MailDraftStore. Before replacing an existing file it
/// decodes that file, so a corrupt snapshot remains available for recovery instead of being
/// silently replaced by a new empty one.
private enum MailOwnedJSONTransactions {
    static let lock = NSLock()
    static let maxBytes = 100 * 1024 * 1024
}

final class MailOwnedJSONStore<Value: Codable>: @unchecked Sendable {

    let directory: URL
    let fileName: String
    private var file: URL { directory.appendingPathComponent(fileName, isDirectory: false) }

    init(directory: URL, fileName: String) {
        self.directory = directory
        self.fileName = fileName
    }

    func load(or defaultValue: @autoclosure () -> Value) throws -> Value {
        try MailOwnedJSONTransactions.lock.withLock {
            if pathExists(directory) { try check(directory, directory: true) }
            guard pathExists(file) else { return defaultValue() }
            try check(file, directory: false)
            let data: Data
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= Int64(MailOwnedJSONTransactions.maxBytes) else {
                    throw LauncherError("The local mail state is too large to read.")
                }
                data = try Data(contentsOf: file, options: [.mappedIfSafe])
            } catch let error as LauncherError {
                throw error
            } catch {
                throw LauncherError("The local mail state could not be read: " + error.localizedDescription)
            }
            do {
                return try JSONDecoder().decode(Value.self, from: data)
            } catch {
                throw LauncherError("The local mail state is corrupt and was left untouched. Move " + fileName + " aside to recover.")
            }
        }
    }

    func save(_ value: Value) throws {
        try MailOwnedJSONTransactions.lock.withLock {
            try ensureDirectory()
            // Keep a corrupt file intact. This check is under the same lock as the rename.
            if pathExists(file) {
                try check(file, directory: false)
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    guard (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= Int64(MailOwnedJSONTransactions.maxBytes) else {
                        throw LauncherError("The local mail state is too large to read.")
                    }
                    _ = try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
                } catch let error as LauncherError { throw error }
                catch { throw LauncherError("The local mail state is corrupt and was left untouched. Move " + fileName + " aside to recover.") }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            do { data = try encoder.encode(value) }
            catch { throw LauncherError("The local mail state could not be encoded: " + error.localizedDescription) }
            guard data.count <= MailOwnedJSONTransactions.maxBytes else { throw LauncherError("The local mail state is too large to save.") }

            let temporary = directory.appendingPathComponent("." + fileName + "-" + UUID().uuidString)
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw LauncherError("The local mail state could not be written.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var closed = false
            defer {
                if !closed { try? handle.close() }
                try? FileManager.default.removeItem(at: temporary)
            }
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                guard fsync(descriptor) == 0 else { throw LauncherError("The local mail state could not be synchronized.") }
                try handle.close(); closed = true
            } catch let error as LauncherError { throw error }
            catch { throw LauncherError("The local mail state could not be written: " + error.localizedDescription) }
            guard rename(temporary.path, file.path) == 0 else { throw LauncherError("The local mail state could not be replaced.") }
            let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryDescriptor >= 0 else { throw LauncherError("The local mail state folder could not be opened.") }
            defer { close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else { throw LauncherError("The local mail state folder could not be synchronized.") }
        }
    }

    private func ensureDirectory() throws {
        if pathExists(directory) {
            try check(directory, directory: true)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try check(directory, directory: true)
        } catch let error as LauncherError { throw error }
        catch { throw LauncherError("The local mail state folder could not be created: " + error.localizedDescription) }
    }

    private func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func check(_ url: URL, directory: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            throw LauncherError("Jevcast could not safely open local mail state. Check its permissions.")
        }
        try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
}

final class MailSnoozeStore: @unchecked Sendable {
    let directory: URL
    private let file: MailOwnedJSONStore<MailSnoozeStoreSnapshot>

    init(directory: URL) {
        self.directory = directory
        file = MailOwnedJSONStore(directory: directory, fileName: "snoozes.json")
    }

    static var standard: MailSnoozeStore {
        MailSnoozeStore(directory: MailIOPolicy.isOffline ? offlineDirectory : URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Jevcast/MailSnooze", isDirectory: true))
    }

    /// Offline and snapshot runs must never inspect a real user's mail state. The process-scoped
    /// folder still lets two centers in one synthetic run share their local fixture if needed.
    private static let offlineDirectory: URL = {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("jevcast-offline-mail-snooze-\(UUID().uuidString)", isDirectory: true)
    }()

    func load() throws -> MailSnoozeStoreSnapshot { try file.load(or: MailSnoozeStoreSnapshot()) }
    func save(_ snapshot: MailSnoozeStoreSnapshot) throws { try file.save(snapshot) }
}
