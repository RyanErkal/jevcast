import Foundation

/// What a clipboard entry holds. Stored in the index, so never rename a case.
public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text, richText, link, email, phone, color, code, number, image, files

    /// Kinds whose content is text that can be pasted or transformed.
    public var isText: Bool { ![.image, .files].contains(self) }
}

public enum ClipFileCategory: String, Codable, Sendable {
    case image, video, audio, pdf, document, folder, other
}

/// A file copied in Finder. Only the reference is kept, never the file.
public struct ClipFile: Codable, Hashable, Sendable {
    public var path: String
    public var name: String
    /// Finds the file again after it moves.
    public var bookmark: Data?
    public var uti: String?
    public var size: Int64?
    public var category: ClipFileCategory
    /// Seconds, for video and audio.
    public var duration: Double?
    public init(path: String, name: String, bookmark: Data? = nil, uti: String? = nil, size: Int64? = nil,
                category: ClipFileCategory, duration: Double? = nil) {
        self.path = path; self.name = name; self.bookmark = bookmark; self.uti = uti; self.size = size
        self.category = category; self.duration = duration
    }
}

public struct ClipImageInfo: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// The type of the stored image data.
    public var uti: String
    public var byteSize: Int
    public init(width: Int, height: Int, uti: String, byteSize: Int) {
        self.width = width; self.height = height; self.uti = uti; self.byteSize = byteSize
    }
}

/// One clipboard history entry, as kept in the index. Large content lives in blob files beside it.
public struct ClipEntry: Codable, Identifiable, Hashable, Sendable {
    /// Longer text keeps this much in the index, for titles and search, and the rest in a blob.
    public static let indexTextLimit = 4_000

    public var id: UUID
    /// Content hash for de-duplication.
    public var hash: String
    public var kind: ClipKind
    public var firstCopied: Date
    public var copiedAt: Date
    public var pinned: Bool
    /// Plain text, cut to `indexTextLimit` characters. The full text is in the "text" blob when `textInBlob`.
    public var text: String?
    public var textLength: Int
    public var textInBlob: Bool
    /// A guessed language label for code, such as "Swift".
    public var language: String?
    public var hasRTF: Bool
    public var hasHTML: Bool
    public var image: ClipImageInfo?
    public var files: [ClipFile]
    public var hasThumbnail: Bool
    /// Text found in an image on this Mac.
    public var ocrText: String?
    public var sourceBundleID: String?
    public var sourceName: String?
    /// Bytes stored for this entry, including blobs.
    public var byteSize: Int64

    public init(id: UUID = UUID(), hash: String, kind: ClipKind, copiedAt: Date, pinned: Bool = false, text: String? = nil,
                textLength: Int? = nil, textInBlob: Bool = false, language: String? = nil, hasRTF: Bool = false, hasHTML: Bool = false,
                image: ClipImageInfo? = nil, files: [ClipFile] = [], hasThumbnail: Bool = false, ocrText: String? = nil,
                sourceBundleID: String? = nil, sourceName: String? = nil, byteSize: Int64 = 0) {
        self.id = id; self.hash = hash; self.kind = kind; self.firstCopied = copiedAt; self.copiedAt = copiedAt; self.pinned = pinned
        self.text = text; self.textLength = textLength ?? text?.count ?? 0; self.textInBlob = textInBlob; self.language = language
        self.hasRTF = hasRTF; self.hasHTML = hasHTML; self.image = image; self.files = files; self.hasThumbnail = hasThumbnail
        self.ocrText = ocrText; self.sourceBundleID = sourceBundleID; self.sourceName = sourceName
        self.byteSize = byteSize > 0 ? byteSize : Int64(text?.utf8.count ?? 0)
    }

    /// True when every file is a video or audio file.
    public var isMedia: Bool { kind == .files && !files.isEmpty && files.allSatisfy { $0.category == .video || $0.category == .audio } }
    /// A copied image, or image files.
    public var isImage: Bool { kind == .image || (kind == .files && !files.isEmpty && files.allSatisfy { $0.category == .image }) }

    /// The host of a link, such as "github.com".
    public var linkHost: String? {
        guard kind == .link, let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: value.hasPrefix("www.") ? "https://" + value : value)?.host
    }

    /// One line for a list row.
    public var title: String {
        switch kind {
        case .image:
            if let first = ocrText?.split(whereSeparator: \.isNewline).first { return "Image: " + String(first.prefix(80)) }
            return "Image"
        case .files:
            guard let first = files.first else { return "Files" }
            return files.count == 1 ? first.name : "\(first.name) and \(files.count - 1) more"
        default:
            let value = text ?? ""
            let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
        }
    }

    /// Blob file names.
    public enum Blob {
        public static let text = "text.txt"
        public static let rtf = "rich.rtf"
        public static let html = "rich.html"
        public static let image = "image"
        public static let thumbnail = "thumb.png"
    }
}

/// The app that was in front when something was copied.
public struct ClipSource: Equatable, Sendable {
    public var bundleID: String?
    public var name: String?
    public init(bundleID: String?, name: String?) { self.bundleID = bundleID; self.name = name }
}
