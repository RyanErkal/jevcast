import AppKit
import LauncherCore
import UniformTypeIdentifiers

/// What one copy put on the pasteboard, read once and handed to the worker.
struct ClipRaw: Sendable {
    var types: [String]
    var string: String?
    var rtf: Data?
    var html: Data?
    /// The first image representation and its type.
    var image: (data: Data, uti: String)?
    var fileURLs: [URL] = []
    var url: String?
    /// An image was on the pasteboard but was over the size limit.
    var imageTooLarge = false

    init(types: [String], string: String? = nil, rtf: Data? = nil, html: Data? = nil, image: (data: Data, uti: String)? = nil,
         fileURLs: [URL] = [], url: String? = nil) {
        self.types = types; self.string = string; self.rtf = rtf; self.html = html; self.image = image
        self.fileURLs = fileURLs; self.url = url
    }

    static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"]
}

/// What to put back on the pasteboard.
struct ClipPayload: Sendable {
    var string: String?
    /// Extra representations by type, such as RTF, HTML, or image data.
    var data: [(type: String, data: Data)] = []
    var fileURLs: [URL] = []
}

/// The pasteboard surface ClipboardHistory needs, so tests can inject a fake.
@MainActor
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    var types: [String] { get }
    func string() -> String?
    /// Writes plain text and returns the new change count.
    func write(_ text: String) -> Int
    /// Reads the current contents off the main thread. Nil when the change count is no longer `expected`.
    func read(limit: Int, expected: Int) async -> ClipRaw?
    /// Writes an entry and returns the new change count.
    func write(_ payload: ClipPayload) -> Int
}

extension PasteboardReading {
    func read(limit: Int, expected: Int) async -> ClipRaw? {
        guard changeCount == expected else { return nil }
        return string().map { ClipRaw(types: types, string: $0) }
    }
    func write(_ payload: ClipPayload) -> Int {
        write(payload.string ?? payload.fileURLs.map(\.path).joined(separator: "\n"))
    }
}

@MainActor
final class SystemPasteboard: PasteboardReading {
    private let pasteboard = NSPasteboard.general
    var changeCount: Int { pasteboard.changeCount }
    var types: [String] { pasteboard.types?.map(\.rawValue) ?? [] }
    func string() -> String? { pasteboard.string(forType: .string) }
    func write(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    func read(limit: Int, expected: Int) async -> ClipRaw? {
        // Something newer was copied since the poll, or while reading; the poll for that copy checks it instead.
        guard pasteboard.changeCount == expected else { return nil }
        let raw = await Task.detached(priority: .userInitiated) { () -> ClipRaw? in
            guard NSPasteboard.general.changeCount == expected else { return nil }
            let raw = Self.readGeneral(limit: limit)
            return NSPasteboard.general.changeCount == expected ? raw : nil
        }.value
        return NSPasteboard.general.changeCount == expected ? raw : nil
    }

    /// Reads NSPasteboard.general. Safe off the main thread for reading.
    nonisolated private static func readGeneral(limit: Int) -> ClipRaw? {
        let board = NSPasteboard.general
        guard let item = board.pasteboardItems?.first else { return nil }
        let types = (board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        guard !types.contains(where: { ClipboardHistory.skippedTypes.contains($0) }) else { return nil }
        var raw = ClipRaw(types: types)
        raw.string = item.string(forType: .string)
        raw.rtf = item.data(forType: .rtf)
        raw.html = item.data(forType: .html)
        raw.url = item.string(forType: .URL)
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        raw.fileURLs = urls.filter(\.isFileURL)
        if raw.fileURLs.isEmpty, let type = types.first(where: { ClipRaw.imageTypes.contains($0) }),
           let data = item.data(forType: NSPasteboard.PasteboardType(type)), data.count <= limit {
            raw.image = (data, type)
        } else if raw.fileURLs.isEmpty, types.contains(where: { ClipRaw.imageTypes.contains($0) }) {
            raw.imageTooLarge = true
        }
        return raw
    }

    func write(_ payload: ClipPayload) -> Int {
        pasteboard.clearContents()
        if !payload.fileURLs.isEmpty {
            pasteboard.writeObjects(payload.fileURLs.map { $0 as NSURL })
            return pasteboard.changeCount
        }
        let item = NSPasteboardItem()
        for (type, data) in payload.data { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        if let string = payload.string { item.setString(string, forType: .string) }
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }
}
