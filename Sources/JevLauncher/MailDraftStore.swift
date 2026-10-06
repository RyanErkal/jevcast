import Foundation
import LauncherCore

struct MailDelivery: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case queued, sending, sent, sentCopyPending, appleMailQueued, failed, uncertain, undone }
    var id: UUID
    var draft: MailModel.Draft?
    var subject: String
    var recipient: String
    var date: Date
    var state: State
    var note: String?
    var receipt: MailSendReceipt? = nil
    var serverDraftCleanupReferences: [MailServerDraftReference]?
}

/// Composition storage only. Recovery never resumes a send automatically.
///
/// The synchronous `save` method is kept for deterministic startup and tests. UI autosaves must
/// use `saveAsync`: JSON encoding and the file operation then run on this store's private serial
/// queue instead of blocking the main actor.
final class MailDraftStore: @unchecked Sendable {
    struct Snapshot: Codable, Sendable {
        var active: MailModel.Draft?
        var unsent: [MailModel.Unsent] = []
        var deliveries: [MailDelivery] = []
    }

    /// The file is deliberately bounded. The composer already limits attachments to 18 MB, but
    /// the larger snapshot limit lets an old valid draft be read without a format migration.
    private static let maxSnapshotBytes = 100 * 1024 * 1024
    private static let maxAttachmentCount = 30
    private static let maxFilenameBytes = 4 * 1024
    private static let maxMIMETypeBytes = 1024
    private static let maxContentIDBytes = 2 * 1024
    private static let maxUnsentCount = 10_000
    private static let maxDeliveryCount = 10_000

    /// Different MailDraftStore instances can point at the same folder during startup and a
    /// close/send race. This lock keeps their read/validate/write transactions ordered too.
    private static let transactionLock = NSLock()

    /// Cancellation-aware admission for an asynchronous save. A canceled request that has not
    /// reached the writer is skipped, while a request already writing remains ordered before later
    /// saves. This closes the race where an autosave Task is canceled before its queue block starts.
    private final class SaveRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var completed = false
        private var continuation: CheckedContinuation<Void, Error>?

        func begin(_ continuation: CheckedContinuation<Void, Error>, enqueue: () -> Void) {
            lock.lock()
            let skip = cancelled
            if !skip { self.continuation = continuation }
            else { completed = true }
            lock.unlock()
            if skip { continuation.resume(throwing: CancellationError()) }
            else { enqueue() }
        }

        func shouldWrite() -> Bool {
            lock.withLock { !cancelled && !completed }
        }

        func cancel() {
            let pending: CheckedContinuation<Void, Error>?
            lock.lock()
            cancelled = true
            if !completed, let continuation {
                completed = true
                self.continuation = nil
                pending = continuation
            } else {
                pending = nil
            }
            lock.unlock()
            pending?.resume(throwing: CancellationError())
        }

        func finish(_ result: Result<Void, Error>) {
            let pending: CheckedContinuation<Void, Error>?
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            switch result {
            case .success: pending.resume()
            case let .failure(error): pending.resume(throwing: error)
            }
        }
    }

    let directory: URL
    private var file: URL { directory.appendingPathComponent("composition.json") }
    private let writer: DispatchQueue

    init(directory: URL) {
        self.directory = directory
        writer = DispatchQueue(label: "jevcast.mail.composition." + UUID().uuidString, qos: .utility)
    }

    static var standard: MailDraftStore? {
        guard !MailIOPolicy.isOffline else { return nil }
        return MailDraftStore(directory: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Jevcast/MailComposition", isDirectory: true))
    }

    /// Loads the one canonical JSON representation. A corrupt file is an explicit recovery
    /// condition: it is not silently replaced with an empty snapshot.
    func load() throws -> Snapshot {
        try Self.transactionLock.withLock {
            try loadOnTransaction()
        }
    }

    /// Enqueues one ordered save. Cancellation of the caller does not cancel a write already
    /// admitted to the queue. That is intentional: a later forced save is queued after it and
    /// therefore remains the final state instead of being overtaken by a canceled autosave.
    func saveAsync(_ snapshot: Snapshot) async throws {
        let request = SaveRequest()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                request.begin(continuation) { [self] in
                    writer.async { [self] in
                        guard request.shouldWrite() else {
                            request.finish(.failure(CancellationError()))
                            return
                        }
                        do {
                            try Self.transactionLock.withLock { try saveOnTransaction(snapshot) }
                            request.finish(.success(()))
                        } catch {
                            request.finish(.failure(error))
                        }
                    }
                }
            }
        }, onCancel: {
            request.cancel()
        })
    }

    /// Synchronous save for startup and deterministic isolated tests. Production autosaves and
    /// send-state checkpoints should call `saveAsync` so encoding cannot run on MainActor.
    func save(_ snapshot: Snapshot) throws {
        try writer.sync {
            try Self.transactionLock.withLock { try saveOnTransaction(snapshot) }
        }
    }

    private func loadOnTransaction() throws -> Snapshot {
        if pathExists(directory) {
            try check(directory, directory: true)
        }
        guard pathExists(file) else { return Snapshot() }
        try check(file, directory: false)
        let snapshot = try readSnapshot()
        return recover(snapshot)
    }

    private func saveOnTransaction(_ snapshot: Snapshot) throws {
        try ensureDirectory()

        // Never replace a file that cannot be decoded. This check is done while holding the same
        // transaction lock as the rename, so a corrupt snapshot remains available for recovery.
        if pathExists(file) {
            try check(file, directory: false)
            _ = try readSnapshot()
        }

        try validate(snapshot)
        let encoder = JSONEncoder()
        // Stable key ordering is the only canonical-format choice. Date encoding stays at
        // Foundation's existing default so valid older snapshots remain readable in place.
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw LauncherError("The saved mail drafts could not be encoded: " + error.localizedDescription)
        }
        guard data.count <= Self.maxSnapshotBytes else {
            throw LauncherError("The saved mail drafts are too large. Remove some attachments before sending.")
        }

        let temporary = directory.appendingPathComponent(".composition-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LauncherError("The saved mail drafts could not be written.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var closed = false
        defer {
            if !closed { try? handle.close() }
            try? FileManager.default.removeItem(at: temporary)
        }

        do {
            try handle.write(contentsOf: data)
            // `synchronize` flushes Foundation's buffered handle and the explicit fsync makes the
            // durability requirement visible here before the atomic replacement.
            try handle.synchronize()
            guard fsync(fd) == 0 else { throw LauncherError("The saved mail drafts could not be synchronized.") }
            try handle.close()
            closed = true
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError("The saved mail drafts could not be written: " + error.localizedDescription)
        }

        guard rename(temporary.path, file.path) == 0 else {
            throw LauncherError("The saved mail drafts could not be replaced.")
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw LauncherError("The saved mail drafts folder could not be synchronized.") }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw LauncherError("The saved mail drafts folder could not be synchronized.") }
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if pathExists(directory) {
            try check(directory, directory: true)
            return
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try check(directory, directory: true)
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError("The saved mail drafts folder could not be created: " + error.localizedDescription)
        }
    }

    private func readSnapshot() throws -> Snapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= Int64(Self.maxSnapshotBytes) else {
            throw LauncherError("The saved mail drafts are too large to read.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: file, options: [.mappedIfSafe])
        } catch {
            throw LauncherError("The saved mail drafts could not be read: " + error.localizedDescription)
        }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            try validate(snapshot)
            return snapshot
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError("The saved mail drafts are corrupt and were left untouched. Move composition.json aside to recover.")
        }
    }

    private func recover(_ snapshot: Snapshot) -> Snapshot {
        var snapshot = snapshot
        var recovered: [MailModel.Unsent] = []
        for index in snapshot.deliveries.indices {
            let item = snapshot.deliveries[index]
            guard var draft = item.draft, [.queued, .sending].contains(item.state) else { continue }
            draft.uncertainSend = item.state == .sending
            let reason = draft.uncertainSend ? "This message may already be sent. Check Sent before resending." : "Not sent. Recovered after restart."
            snapshot.deliveries[index].state = draft.uncertainSend ? .uncertain : .failed
            snapshot.deliveries[index].draft = draft
            snapshot.deliveries[index].note = reason
            recovered.append(.init(draft: draft, reason: reason))
        }
        for item in recovered where !snapshot.unsent.contains(where: { $0.id == item.id }) && snapshot.active?.id != item.id {
            snapshot.unsent.append(item)
        }
        for item in recovered {
            if snapshot.active?.id == item.id { snapshot.active = item.draft }
            if let index = snapshot.unsent.firstIndex(where: { $0.id == item.id }) { snapshot.unsent[index] = item }
        }
        return snapshot
    }

    private func validate(_ snapshot: Snapshot) throws {
        guard snapshot.unsent.count <= Self.maxUnsentCount else { throw invalidSnapshot("too many unsent drafts") }
        guard snapshot.deliveries.count <= Self.maxDeliveryCount else { throw invalidSnapshot("too many delivery records") }
        if let active = snapshot.active { try validate(active) }
        for item in snapshot.unsent { try validate(item.draft) }
        for item in snapshot.deliveries {
            if let draft = item.draft { try validate(draft) }
            guard item.subject.utf8.count <= 4 * 1024, item.recipient.utf8.count <= 4 * 1024,
                  item.note?.utf8.count ?? 0 <= 16 * 1024 else {
                throw invalidSnapshot("delivery metadata is too large")
            }
            if let receipt = item.receipt {
                guard receipt.accountID.utf8.count <= 4 * 1024,
                      receipt.messageID.utf8.count <= 4 * 1024,
                      receipt.note?.utf8.count ?? 0 <= 16 * 1024,
                      receipt.message?.count ?? 0 <= Self.maxSnapshotBytes else {
                    throw invalidSnapshot("send receipt metadata is too large")
                }
            }
        }
    }

    private func validate(_ draft: MailModel.Draft) throws {
        guard draft.attachments.count <= Self.maxAttachmentCount else { throw invalidSnapshot("too many attachments") }
        for attachment in draft.attachments {
            guard attachment.filename.utf8.count <= Self.maxFilenameBytes,
                  attachment.mimeType.utf8.count <= Self.maxMIMETypeBytes,
                  attachment.contentID?.utf8.count ?? 0 <= Self.maxContentIDBytes else {
                throw invalidSnapshot("attachment metadata is too large")
            }
        }
    }

    private func invalidSnapshot(_ reason: String) -> LauncherError {
        LauncherError("The saved mail drafts are invalid: " + reason + ".")
    }

    /// `FileManager.fileExists` follows links and reports false for a dangling link. `lstat`
    /// preserves the safety check for both forms, including an abandoned symlink to a store.
    private func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func check(_ url: URL, directory: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            throw LauncherError("Jevcast could not safely open the saved mail drafts. Check the MailComposition folder permissions.")
        }
        try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
}
