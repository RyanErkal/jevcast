import Foundation
import Darwin
import LauncherCore

/// Blob files and the index for clipboard history. With a folder, everything is on disk
/// (folder 0700, files 0600); without one, blobs stay in memory. Used only by ClipboardWorker,
/// so one thread touches it at a time.
final class ClipboardStore {
    private(set) var folder: URL?
    private var memory: [UUID: [String: Data]] = [:]
    private let fm = FileManager.default

    init(folder: URL?) { self.folder = folder }

    static var defaultFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Jevcast/Clipboard", isDirectory: true)
    }

    private struct IndexFile: Codable {
        var version = 1
        var entries: [ClipEntry]
    }

    private var indexURL: URL? { folder?.appendingPathComponent("index.json") }
    private func itemFolder(_ id: UUID) -> URL? { folder?.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func prepare(_ url: URL) throws {
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeFile(_ data: Data, to url: URL) throws {
        // mkstemp creates the staging file with mode 0600 before any private bytes are written.
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".clipboard-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let temporary = String(cString: template)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary, url.path) == 0 else { throw POSIXError(.EIO) }
    }

    // MARK: Index

    /// Entries in the index, newest first. Folders with no entry, left by a quit during a delete, are removed.
    func loadIndex() -> [ClipEntry] {
        guard let folder, let url = indexURL else { return [] }
        let file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(IndexFile.self, from: $0) }
        let entries = file?.version == 1 ? file?.entries ?? [] : []
        let ids = Set(entries.map(\.id))
        let children = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in children {
            guard let id = UUID(uuidString: name), !ids.contains(id) else { continue }
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        return entries
    }

    func saveIndex(_ entries: [ClipEntry]) {
        guard let folder, let url = indexURL else { return }
        do {
            try prepare(folder)
            try writeFile(try JSONEncoder().encode(IndexFile(entries: entries)), to: url)
        } catch {
            NSLog("[Jev clipboard] The index could not be saved.")
        }
    }

    // MARK: Blobs

    func write(_ blobs: [String: Data], for id: UUID) {
        guard !blobs.isEmpty else { return }
        guard let folder, let item = itemFolder(id) else { memory[id, default: [:]].merge(blobs) { $1 }; return }
        do {
            try prepare(folder); try prepare(item)
            for (name, data) in blobs { try writeFile(data, to: item.appendingPathComponent(name)) }
        } catch {
            NSLog("[Jev clipboard] An item could not be saved.")
        }
    }

    func read(_ name: String, for id: UUID) -> Data? {
        guard let item = itemFolder(id) else { return memory[id]?[name] }
        return try? Data(contentsOf: item.appendingPathComponent(name))
    }

    /// A file for Quick Look, or nil when blobs are in memory.
    func fileURL(_ name: String, for id: UUID) -> URL? {
        guard let url = itemFolder(id)?.appendingPathComponent(name), fm.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func delete(_ ids: some Sequence<UUID>) {
        for id in ids {
            memory[id] = nil
            if let item = itemFolder(id) { try? fm.removeItem(at: item) }
        }
    }

    /// Moves every blob on disk into memory, including entries not yet in the index, and deletes the folder.
    func goMemoryOnly() {
        guard let folder else { return }
        var moved: [UUID: [String: Data]] = [:]
        for child in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard let id = UUID(uuidString: child), let item = itemFolder(id),
                  let names = try? fm.contentsOfDirectory(atPath: item.path) else { continue }
            var blobs: [String: Data] = [:]
            for name in names { blobs[name] = try? Data(contentsOf: item.appendingPathComponent(name)) }
            moved[id] = blobs
        }
        try? fm.removeItem(at: folder)
        self.folder = nil
        memory = moved
    }

    /// Writes memory blobs and the index into `folder`.
    func goPersistent(_ folder: URL, entries: [ClipEntry]) {
        self.folder = folder
        let blobs = memory
        memory = [:]
        for (id, items) in blobs { write(items, for: id) }
        saveIndex(entries)
    }

    /// Removes the whole folder, or all memory blobs.
    func deleteAll() {
        memory = [:]
        if let folder { try? fm.removeItem(at: folder) }
        Self.removePreviewFiles()
    }

    /// Temporary files Quick Look shows, in a private folder. Removed when they close, at launch, and when history is cleared.
    static var previewFolder: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("JevcastClipboardPreview", isDirectory: true)
    }
    static func removePreviewFiles() { try? FileManager.default.removeItem(at: previewFolder) }
}
