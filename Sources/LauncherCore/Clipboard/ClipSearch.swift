import Foundation

/// The chips at the top of the Clipboard view.
public enum ClipFilter: String, CaseIterable, Sendable {
    case all, pinned, text, images, links, files, media, colors, code

    public var title: String {
        switch self {
        case .all: return "All"; case .pinned: return "Pinned"; case .text: return "Text"
        case .images: return "Images"; case .links: return "Links"; case .files: return "Files"
        case .media: return "Media"; case .colors: return "Colors"; case .code: return "Code"
        }
    }

    public func includes(_ entry: ClipEntry) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return entry.pinned
        case .text: return [.text, .richText, .email, .phone, .number, .code].contains(entry.kind)
        case .images: return entry.isImage
        case .links: return entry.kind == .link
        case .files: return entry.kind == .files
        case .media: return entry.isMedia
        case .colors: return entry.kind == .color
        case .code: return entry.kind == .code
        }
    }

    /// Words after "clip" that pick a chip.
    var words: [String] {
        switch self {
        case .all: return []
        case .pinned: return ["pinned", "pins", "pin"]
        case .text: return ["text", "texts"]
        case .images: return ["image", "images", "picture", "pictures", "screenshot", "screenshots"]
        case .links: return ["link", "links", "url", "urls"]
        case .files: return ["file", "files"]
        case .media: return ["media", "video", "videos", "audio"]
        case .colors: return ["color", "colors", "colour", "colours"]
        case .code: return ["code", "snippet", "snippets"]
        }
    }
}

/// A filter typed in the search field: an optional chip or kind word first, then words to find.
public struct ClipQuery: Equatable, Sendable {
    public var filter: ClipFilter?
    /// "emails" and "numbers" narrow to a kind that has no chip.
    public var kind: ClipKind?
    public var words: [String]

    public init(filter: ClipFilter? = nil, kind: ClipKind? = nil, words: [String] = []) {
        self.filter = filter; self.kind = kind; self.words = words
    }

    public static func parse(_ text: String) -> ClipQuery {
        var words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return ClipQuery() }
        if let filter = ClipFilter.allCases.first(where: { $0.words.contains(first) }) {
            words.removeFirst(); return ClipQuery(filter: filter, words: words)
        }
        let kinds: [(ClipKind, [String])] = [(.email, ["email", "emails"]), (.number, ["number", "numbers"]), (.phone, ["phone", "phones"])]
        if let kind = kinds.first(where: { $0.1.contains(first) })?.0 {
            words.removeFirst(); return ClipQuery(kind: kind, words: words)
        }
        return ClipQuery(words: words)
    }
}

public enum ClipSearch {
    /// Lower-case text searched for an entry: text, text found in images, file names, source app, and link host.
    public static func key(for entry: ClipEntry) -> String {
        var parts: [String] = []
        if let text = entry.text { parts.append(String(text.prefix(ClipEntry.indexTextLimit))) }
        if let ocr = entry.ocrText { parts.append(ocr) }
        parts += entry.files.map(\.name)
        if let source = entry.sourceName { parts.append(source) }
        if let host = entry.linkHost { parts.append(host) }
        if let language = entry.language { parts.append(language) }
        return parts.joined(separator: "\n").lowercased()
    }

    /// Pinned first, then newest, narrowed by the chip, the query's kind, and every word.
    /// `keys` holds each entry's `key(for:)`, made once when the entry changes.
    public static func filter(_ entries: [ClipEntry], keys: [UUID: String], chip: ClipFilter, query: ClipQuery) -> [ClipEntry] {
        let chip = query.filter ?? chip
        var pinned: [ClipEntry] = [], rest: [ClipEntry] = []
        for entry in entries {
            guard chip.includes(entry) else { continue }
            if let kind = query.kind, entry.kind != kind { continue }
            if !query.words.isEmpty {
                let key = keys[entry.id] ?? key(for: entry)
                guard query.words.allSatisfy({ key.contains($0) }) else { continue }
            }
            if entry.pinned { pinned.append(entry) } else { rest.append(entry) }
        }
        return pinned + rest
    }

    /// Text for several entries copied at once, in order, one per line. Images have no text and are left out.
    public static func joined(_ entries: [ClipEntry], fullText: (ClipEntry) -> String? = { $0.text }) -> String {
        entries.compactMap { entry -> String? in
            switch entry.kind {
            case .image: return nil
            case .files: return entry.files.map(\.path).joined(separator: "\n")
            default: return fullText(entry)
            }
        }.joined(separator: "\n")
    }
}
