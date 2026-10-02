import Foundation
import LauncherCore

struct MailDelivery: Codable, Identifiable {
    enum State: String, Codable { case queued, sending, sent, failed, uncertain, undone }
    var id: UUID
    var draft: MailModel.Draft?
    var subject: String
    var recipient: String
    var date: Date
    var state: State
    var note: String?
}

/// Composition storage only. Recovery never resumes a send automatically.
final class MailDraftStore {
    struct Snapshot: Codable {
        var active: MailModel.Draft?
        var unsent: [MailModel.Unsent] = []
        var deliveries: [MailDelivery] = []
    }
    let directory: URL
    private var file: URL { directory.appendingPathComponent("composition.json") }
    init(directory: URL) { self.directory = directory }

    static var standard: MailDraftStore? {
        guard !MailIOPolicy.isOffline else { return nil }
        return MailDraftStore(directory: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Jevcast/MailComposition", isDirectory: true))
    }

    func load() throws -> Snapshot {
        if FileManager.default.fileExists(atPath: directory.path) { try check(directory, directory: true) }
        guard FileManager.default.fileExists(atPath: file.path) else { return Snapshot() }
        try check(file, directory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? Int ?? Int.max) <= 100 * 1024 * 1024 else { throw LauncherError("The saved mail drafts are too large to read.") }
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        var recovered: [MailModel.Unsent] = []
        for index in snapshot.deliveries.indices {
            let item = snapshot.deliveries[index]
            guard var draft = item.draft, [.queued, .sending].contains(item.state) else { continue }
            draft.uncertainSend = item.state == .sending
            let reason = draft.uncertainSend ? "This message may already be sent. Check Sent before resending." : "Not sent. Recovered after restart."
            snapshot.deliveries[index].state = draft.uncertainSend ? .uncertain : .failed
            snapshot.deliveries[index].draft = draft; snapshot.deliveries[index].note = reason
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

    func save(_ snapshot: Snapshot) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try check(directory, directory: true) }
        else { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        if fm.fileExists(atPath: file.path) { try check(file, directory: false) }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 100 * 1024 * 1024 else { throw LauncherError("The saved mail drafts are too large. Remove some attachments before sending.") }
        let temporary = directory.appendingPathComponent(".composition-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LauncherError("The saved mail drafts could not be written.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw LauncherError("The saved mail drafts could not be replaced.") }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw LauncherError("The saved mail drafts folder could not be synchronized.") }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw LauncherError("The saved mail drafts folder could not be synchronized.") }
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
