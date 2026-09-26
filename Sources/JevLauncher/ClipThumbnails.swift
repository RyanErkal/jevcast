import AppKit
import LauncherCore

/// Decoded thumbnails and previews, kept in a small LRU cache. Decoding runs on the worker,
/// never in a view body.
@MainActor
final class ClipThumbnails {
    private let worker: ClipboardWorker
    private var cache: [UUID: NSImage] = [:]
    private var order: [UUID] = []
    private let limit = 300
    private var previews: [UUID: NSImage] = [:]
    private var previewOrder: [UUID] = []

    init(worker: ClipboardWorker) { self.worker = worker }

    func cached(_ id: UUID) -> NSImage? { cache[id] }

    func thumbnail(for entry: ClipEntry) async -> NSImage? {
        if let hit = cache[entry.id] { touch(entry.id); return hit }
        guard entry.hasThumbnail || entry.kind == .image else { return nil }
        guard let image = await worker.thumbnail(for: entry, maxPixels: 160) else { return nil }
        let made = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        store(made, for: entry.id)
        return made
    }

    /// A large image for the preview pane. Only the last few are kept.
    func preview(for entry: ClipEntry) async -> NSImage? {
        if let hit = previews[entry.id] { return hit }
        guard let image = await worker.previewImage(for: entry, maxPixels: 1600) else { return nil }
        let made = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        previews[entry.id] = made
        previewOrder.removeAll { $0 == entry.id }
        previewOrder.append(entry.id)
        if previewOrder.count > 6 { previews[previewOrder.removeFirst()] = nil }
        return made
    }

    private func store(_ image: NSImage, for id: UUID) {
        cache[id] = image
        touch(id)
        if order.count > limit { cache[order.removeFirst()] = nil }
    }
    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

/// App icons by bundle ID, looked up once.
@MainActor
enum ClipAppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, !missing.contains(bundleID) else { return nil }
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { missing.insert(bundleID); return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        cache[bundleID] = icon
        return icon
    }
}
