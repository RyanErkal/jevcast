import CoreGraphics
import Foundation
import LauncherCore

/// The serial worker for clipboard history: reading large data, hashing, encoding, thumbnails,
/// and disk I/O all happen here, off the main thread.
actor ClipboardWorker {
    enum Ingest: Equatable {
        case added(ClipEntry)
        /// The same content is already in the history under this ID.
        case duplicate(UUID)
        case skipped(String)
    }

    private let store: ClipboardStore
    /// Where history is kept after restart. Nil for memory-only workers such as tests and snapshots.
    let folder: URL?
    private var hashes: [String: UUID] = [:]
    private var hashByID: [UUID: String] = [:]

    init(folder: URL?, persist: Bool) {
        self.folder = folder
        store = ClipboardStore(folder: persist ? folder : nil)
    }

    var isPersistent: Bool { store.folder != nil }

    func load() -> [ClipEntry] {
        let entries = store.loadIndex()
        for entry in entries { remember(entry) }
        return entries
    }

    private func remember(_ entry: ClipEntry) {
        hashes[entry.hash] = entry.id
        hashByID[entry.id] = entry.hash
    }

    func ingest(_ raw: ClipRaw, source: ClipSource?, settings: ClipboardSettings, now: Date) async -> Ingest {
        switch await ClipboardCapture.make(raw, source: source, settings: settings, now: now) {
        case .skipped(let reason): return .skipped(reason)
        case .made(let made): return add(made.entry, blobs: made.blobs)
        }
    }

    /// Adds a made entry, such as a transform result or demo data, unless its content is already kept.
    func add(_ entry: ClipEntry, blobs: [String: Data]) -> Ingest {
        if let existing = hashes[entry.hash] { return .duplicate(existing) }
        store.write(blobs, for: entry.id)
        remember(entry)
        return .added(entry)
    }

    func forget(_ ids: [UUID]) {
        for id in ids {
            if let hash = hashByID.removeValue(forKey: id) { hashes[hash] = nil }
        }
        store.delete(ids)
    }

    func saveIndex(_ entries: [ClipEntry]) { store.saveIndex(entries) }

    func read(_ name: String, for id: UUID) -> Data? { store.read(name, for: id) }
    func fileURL(_ name: String, for id: UUID) -> URL? { store.fileURL(name, for: id) }
    func write(_ blobs: [String: Data], for id: UUID) { store.write(blobs, for: id) }

    /// Turns keeping after restart on or off. Off deletes the folder and keeps blobs in memory.
    func setPersistent(_ persist: Bool, entries: [ClipEntry]) {
        guard let folder else { return }
        if persist, store.folder == nil { store.goPersistent(folder, entries: entries) }
        if !persist, store.folder != nil { store.goMemoryOnly() }
    }

    /// Deletes everything, on disk and in memory.
    func deleteAll() {
        store.deleteAll()
        hashes = [:]; hashByID = [:]
    }

    /// The decoded thumbnail, or for images without one, a small decode of the image.
    func thumbnail(for entry: ClipEntry, maxPixels: Int) -> CGImage? {
        if entry.hasThumbnail, let data = store.read(ClipEntry.Blob.thumbnail, for: entry.id) {
            return ClipboardCapture.decode(data, maxPixels: maxPixels)
        }
        guard entry.kind == .image, let data = store.read(ClipEntry.Blob.image, for: entry.id) else { return nil }
        return ClipboardCapture.decode(data, maxPixels: maxPixels)
    }

    /// A large decode for the preview pane.
    func previewImage(for entry: ClipEntry, maxPixels: Int) -> CGImage? {
        if entry.kind == .image, let data = store.read(ClipEntry.Blob.image, for: entry.id) {
            return ClipboardCapture.decode(data, maxPixels: maxPixels)
        }
        if entry.kind == .files, let file = entry.files.first, file.category == .image,
           let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe) {
            return ClipboardCapture.decode(data, maxPixels: maxPixels)
        }
        return thumbnail(for: entry, maxPixels: maxPixels)
    }

    func fullText(_ entry: ClipEntry) -> String? {
        guard entry.textInBlob, let data = store.read(ClipEntry.Blob.text, for: entry.id) else { return entry.text }
        return String(data: data, encoding: .utf8) ?? entry.text
    }

    /// Image data for text recognition: a copied image or a single image file.
    func imageDataForOCR(_ entry: ClipEntry) -> Data? {
        if entry.kind == .image { return store.read(ClipEntry.Blob.image, for: entry.id) }
        guard entry.kind == .files, entry.files.count == 1, let file = entry.files.first, file.category == .image,
              (file.size ?? 0) <= Int64(ClipboardSettings.maxImageBytes) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe)
    }

    /// What to write to the pasteboard. Plain text leaves out formatting; for an image it is the text found in it.
    func payload(for entry: ClipEntry, plain: Bool) -> ClipPayload? {
        switch entry.kind {
        case .image:
            if plain { return entry.ocrText.map { ClipPayload(string: $0) } }
            guard let info = entry.image, let data = store.read(ClipEntry.Blob.image, for: entry.id) else { return nil }
            var payload = ClipPayload(data: [(info.uti, data)])
            if info.uti != "public.png", let png = ClipboardCapture.png(from: data) { payload.data.append(("public.png", png)) }
            return payload
        case .files:
            let urls = entry.files.compactMap(Self.resolve)
            guard !urls.isEmpty else { return nil }
            return plain ? ClipPayload(string: urls.map(\.path).joined(separator: "\n")) : ClipPayload(fileURLs: urls)
        default:
            guard let text = fullText(entry) else { return nil }
            var payload = ClipPayload(string: text)
            guard !plain else { return payload }
            if entry.hasRTF, let rtf = store.read(ClipEntry.Blob.rtf, for: entry.id) { payload.data.append(("public.rtf", rtf)) }
            if entry.hasHTML, let html = store.read(ClipEntry.Blob.html, for: entry.id) { payload.data.append(("public.html", html)) }
            if entry.kind == .link { payload.data.append(("public.url", Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) }
            return payload
        }
    }

    /// The file at its path, or where its bookmark says it moved to.
    static func resolve(_ file: ClipFile) -> URL? {
        if FileManager.default.fileExists(atPath: file.path) { return URL(fileURLWithPath: file.path) }
        guard let bookmark = file.bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
