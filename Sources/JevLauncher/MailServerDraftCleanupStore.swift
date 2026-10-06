import Foundation
import LauncherCore

/// A durable pointer to server drafts that still need explicit cleanup. It contains no message
/// body, recipients, or SMTP state, so an accepted delivery can never become resendable through
/// this journal.
struct MailServerDraftCleanupRecord: Codable, Equatable, Identifiable, Sendable {
    let draftID: UUID
    let accepted: Bool
    var references: [MailServerDraftReference]
    var reason: String
    let createdAt: Date
    var id: UUID { draftID }
}

/// Small owner-only journal separate from composition.json. It is intentionally inspectable and
/// never retries a removal on startup; a user action or a later coordinator call must decide what
/// to do with each exact reference.
final class MailServerDraftCleanupStore: @unchecked Sendable {
    let file: URL
    private let writer = DispatchQueue(label: "jevcast.mail.server-draft-cleanup", qos: .utility)

    private static let maxFileBytes = 1 * 1024 * 1024
    private static let maxRecords = 1_000
    private static let maxReferences = 4
    private static let maxReasonBytes = 16 * 1024

    init(file: URL) { self.file = file }

    static var standard: MailServerDraftCleanupStore? {
        guard !MailIOPolicy.isOffline else { return nil }
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Jevcast/MailComposition", isDirectory: true)
        return MailServerDraftCleanupStore(file: directory.appendingPathComponent("server-draft-cleanup.json"))
    }

    func load() throws -> [MailServerDraftCleanupRecord] {
        try writer.sync { try loadUnlocked() }
    }

    func save(_ record: MailServerDraftCleanupRecord) throws {
        try writer.sync { try saveUnlocked(record) }
    }

    func remove(draftID: UUID) throws {
        try writer.sync { try removeUnlocked(draftID: draftID) }
    }

    func update(_ record: MailServerDraftCleanupRecord) throws { try save(record) }

    func saveAsync(_ record: MailServerDraftCleanupRecord) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writer.async {
                do { try self.saveUnlocked(record); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func updateAsync(_ record: MailServerDraftCleanupRecord) async throws { try await saveAsync(record) }

    func removeAsync(draftID: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writer.async {
                do { try self.removeUnlocked(draftID: draftID); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func loadUnlocked() throws -> [MailServerDraftCleanupRecord] {
        try checkDirectoryChain()
        guard lstatExists(file) else { return [] }
        try checkRegular(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= Int64(Self.maxFileBytes) else {
            throw LauncherError("The server-draft cleanup journal is too large to read.")
        }
        do {
            let records = try JSONDecoder().decode([MailServerDraftCleanupRecord].self,
                                                   from: Data(contentsOf: file, options: [.mappedIfSafe]))
            try validate(records)
            return records
        } catch let error as LauncherError { throw error }
        catch { throw LauncherError("The server-draft cleanup journal is corrupt and was left untouched.") }
    }

    private func saveUnlocked(_ record: MailServerDraftCleanupRecord) throws {
        var records = try loadUnlocked()
        records.removeAll { $0.draftID == record.draftID }
        records.append(record)
        try validate(records)
        try writeUnlocked(records)
    }

    private func removeUnlocked(draftID: UUID) throws {
        var records = try loadUnlocked()
        records.removeAll { $0.draftID == draftID }
        if records.isEmpty {
            guard lstatExists(file) else { return }
            guard unlink(file.path) == 0 else {
                throw LauncherError("The server-draft cleanup journal could not be removed.")
            }
            try syncDirectory()
        } else {
            try writeUnlocked(records)
        }
    }

    private func writeUnlocked(_ records: [MailServerDraftCleanupRecord]) throws {
        try ensureDirectoryChain()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        guard data.count <= Self.maxFileBytes else { throw LauncherError("The server-draft cleanup journal is too large.") }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".server-draft-cleanup-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LauncherError("The server-draft cleanup journal could not be written.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var closed = false
        defer {
            if !closed { try? handle.close() }
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard fsync(fd) == 0 else { throw LauncherError("The server-draft cleanup journal could not be synchronized.") }
            try handle.close(); closed = true
        } catch let error as LauncherError { throw error }
        catch { throw LauncherError("The server-draft cleanup journal could not be written.") }
        guard rename(temporary.path, file.path) == 0 else {
            throw LauncherError("The server-draft cleanup journal could not be replaced.")
        }
        try syncDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validate(_ records: [MailServerDraftCleanupRecord]) throws {
        guard records.count <= Self.maxRecords else { throw LauncherError("The server-draft cleanup journal has too many records.") }
        for record in records {
            guard !record.references.isEmpty, record.references.count <= Self.maxReferences,
                  record.reason.utf8.count <= Self.maxReasonBytes else {
                throw LauncherError("The server-draft cleanup journal contains an invalid record.")
            }
            for reference in record.references {
                guard NativeMailStore.isSafeName(reference.accountID), reference.mailboxID > 0,
                      reference.uidValidity > 0, reference.uid > 0,
                      reference.digest.count == 64,
                      reference.digest.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) }),
                      reference.messageID.count <= 998, reference.messageID.first == "<", reference.messageID.last == ">",
                      !reference.messageID.contains(where: { $0.isWhitespace || $0 == "\r" || $0 == "\n" }) else {
                    throw LauncherError("The server-draft cleanup journal contains an invalid reference.")
                }
            }
        }
    }

    private func lstatExists(_ url: URL) -> Bool {
        var info = stat(); return lstat(url.path, &info) == 0
    }

    private func checkRegular(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG else {
            throw LauncherError("Jevcast could not safely open the server-draft cleanup journal.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func checkDirectory(_ url: URL, ownerRequired: Bool, protect: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              !isSymlink(info), !ownerRequired || info.st_uid == geteuid() else {
            throw LauncherError("Jevcast could not safely open the server-draft cleanup folder.")
        }
        if protect {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    private func isSymlink(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFLNK }

    /// Resolves the journal's parent without changing any existing ancestor. Missing path
    /// components are returned to the caller so a read can report an empty journal without
    /// creating it, while a write can create only owner-controlled directories.
    private func directoryResolution() throws -> (directory: URL, missing: [URL]) {
        var current = file.deletingLastPathComponent().standardizedFileURL
        var missing: [URL] = []
        while !lstatExists(current) {
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent != current else { throw LauncherError("The server-draft cleanup folder could not be opened.") }
            current = parent
        }
        // Existing shared ancestors are validation-only. Canonicalize once after checking the
        // nearest existing parent so macOS's root-owned /var alias becomes /private/var without
        // allowing a user-owned symlink to redirect the target folder.
        _ = try checkReadOnlyAncestor(current)
        var ancestor = current.resolvingSymlinksInPath()
        while true {
            guard try checkReadOnlyAncestor(ancestor) else { break }
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        return (file.deletingLastPathComponent().standardizedFileURL, missing)
    }

    /// Parent validation never changes permissions. A root-owned system symlink such as macOS's
    /// `/var` is a trusted boundary for temporary fixtures, but a symlink owned by this user in
    /// the store's parent chain is rejected rather than followed.
    private func checkReadOnlyAncestor(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LauncherError("Jevcast could not safely open the server-draft cleanup folder.")
        }
        if isSymlink(info) {
            guard info.st_uid != geteuid() else {
                throw LauncherError("Jevcast could not safely open the server-draft cleanup folder.")
            }
            return false
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw LauncherError("Jevcast could not safely open the server-draft cleanup folder.")
        }
        return true
    }

    private func checkDirectoryChain() throws {
        let resolution = try directoryResolution()
        guard resolution.missing.isEmpty else { return }
        try checkDirectory(resolution.directory, ownerRequired: true, protect: true)
    }

    private func ensureDirectoryChain() throws {
        let resolution = try directoryResolution()
        for directory in resolution.missing.reversed() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            try checkDirectory(directory, ownerRequired: true, protect: false)
        }
        try checkDirectory(resolution.directory, ownerRequired: true, protect: true)
    }

    private func syncDirectory() throws {
        let directory = file.deletingLastPathComponent()
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LauncherError("The server-draft cleanup folder could not be synchronized.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw LauncherError("The server-draft cleanup folder could not be synchronized.") }
    }
}
