import Foundation

/// The local, deterministic part of a file search request.
///
/// Parsing is deliberately independent of Spotlight. This lets the launcher
/// decide whether a request is a file request before it offers a web search,
/// and it makes date filters straightforward to test with a fixed clock.
public struct FileSearchQuery: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case pdf
        case image
        case document
        case folder
        case audio
        case video

        public var fileExtensions: [String] {
            switch self {
            case .pdf: return ["pdf"]
            case .image: return ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "avif", "raw"]
            case .document: return ["pdf", "txt", "rtf", "md", "markdown", "doc", "docx", "odt", "pages", "xls", "xlsx", "csv", "ppt", "pptx", "key", "numbers", "json", "xml", "html", "htm", "epub", "tex"]
            case .audio: return ["mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg", "oga", "opus", "aac", "caf"]
            case .video: return ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "mpeg", "mpg", "3gp"]
            case .folder: return []
            }
        }
    }

    public enum Modified: String, CaseIterable, Sendable {
        case today
        case yesterday
        case week
    }

    public enum Scope: String, CaseIterable, Sendable {
        case downloads
        case desktop
        case documents
    }

    public let nameQuery: String
    public let kind: Kind?
    public let modified: Modified?
    public let scope: Scope?
    /// An absolute or home-relative path supplied after `in:`.
    public let scopePath: String?
    /// An explicit path supplied as the file request itself.
    public let explicitPath: String?
    public let isExplicitFileSearch: Bool
    public let isValid: Bool
    public let validationError: String?
    public let filterSummary: String

    public init(text: String) {
        let parsed = Self.parseParts(text)
        nameQuery = parsed.nameWords.joined(separator: " ")
        kind = parsed.kind
        modified = parsed.modified
        scope = parsed.scope
        scopePath = parsed.scopePath
        explicitPath = parsed.explicitPath
        isExplicitFileSearch = parsed.explicitIntent
        isValid = parsed.error == nil
        validationError = parsed.error
        filterSummary = Self.makeSummary(
            nameQuery: nameQuery,
            kind: kind,
            modified: modified,
            scope: scope,
            scopePath: scopePath,
            explicitPath: explicitPath,
            error: parsed.error
        )
    }

    public static func parse(_ text: String) -> FileSearchQuery {
        FileSearchQuery(text: text)
    }

    /// Returns the calendar interval represented by `modified:`.
    /// `week` means the calendar week containing `now`, using the supplied
    /// calendar's first weekday and time zone.
    public func modifiedInterval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard let modified else { return nil }
        switch modified {
        case .today:
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        case .yesterday:
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
            return DateInterval(start: start, end: today)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        }
    }

    /// Checks the name, type, and modification filters. Scope containment is
    /// checked by FileSearch because it depends on the configured folders.
    public func matches(
        name: String,
        path: String,
        isDirectory: Bool,
        modifiedDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        if !nameQuery.isEmpty {
            let foldedName = Self.fold(name)
            let allWordsMatch = nameQuery.split(separator: " ").allSatisfy { foldedName.contains(Self.fold(String($0))) }
            guard allWordsMatch else { return false }
        }

        if let kind, !Self.matches(kind: kind, name: name, path: path, isDirectory: isDirectory) {
            return false
        }

        if let interval = modifiedInterval(now: now, calendar: calendar) {
            guard let modifiedDate, modifiedDate >= interval.start, modifiedDate < interval.end else { return false }
        }

        return isValid
    }

    public static func matches(kind: Kind, name: String, path: String, isDirectory: Bool) -> Bool {
        if kind == .folder { return isDirectory }
        if isDirectory { return false }
        let ext = URL(fileURLWithPath: path.isEmpty ? name : path).pathExtension.lowercased()
        return kind.fileExtensions.contains(ext)
    }

    public static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private struct Parts {
        var nameWords: [String] = []
        var kind: Kind?
        var modified: Modified?
        var scope: Scope?
        var scopePath: String?
        var explicitPath: String?
        var explicitIntent = false
        var error: String?
    }

    private struct Token {
        let value: String
        let quoted: Bool
    }

    private static let commandWords: Set<String> = [
        "find", "search", "locate", "look", "show", "list", "open", "get", "retrieve",
        "please", "me", "the", "a", "an", "for", "with", "named", "name", "file", "files",
        "recent", "latest", "newest"
    ]

    private static func parseParts(_ text: String) -> Parts {
        var parts = Parts()
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A pasted path may contain spaces and therefore cannot be recovered
        // from whitespace tokens. Treat a path-only request as one explicit
        // path; quoted paths continue through the tokenizer below.
        if isPath(trimmedText) {
            parts.explicitPath = trimmedText
            parts.explicitIntent = true
            return parts
        }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return parts }
        // Keep ambiguous words such as "Music" and "Photos" available for
        // normal launcher matching. A file command, a filter, or an
        // unambiguous plural kind gives those words file meaning.
        var explicitFileContext = tokens.contains { token in
            guard !token.quoted else { return false }
            let value = fold(token.value).lowercased()
            return ["find", "locate", "file", "files", "folder", "folders", "pdf", "pdfs", "images", "documents", "audios", "videos"].contains(value)
                || value.hasPrefix("kind:") || value.hasPrefix("type:") || value.hasPrefix("modified:") || value.hasPrefix("date:") || value.hasPrefix("in:")
        }
        var index = 0

        func setKind(_ value: Kind) {
            if let existing = parts.kind, existing != value {
                parts.error = "Only one file kind can be used at a time."
            } else {
                parts.kind = value
            }
        }

        func setModified(_ value: Modified) {
            if let existing = parts.modified, existing != value {
                parts.error = "Only one modified date can be used at a time."
            } else {
                parts.modified = value
            }
        }

        func setScope(_ value: String) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                parts.error = "Add a folder after in:."
                return
            }
            let folded = fold(cleaned).lowercased()
            if let scope = Scope(rawValue: folded) {
                if parts.scope != nil || parts.scopePath != nil {
                    parts.error = "Only one search folder can be used at a time."
                } else {
                    parts.scope = scope
                }
            } else if isPath(cleaned) {
                if parts.scope != nil || parts.scopePath != nil {
                    parts.error = "Only one search folder can be used at a time."
                } else {
                    parts.scopePath = cleaned
                }
            } else {
                parts.error = "Use Downloads, Desktop, Documents, or a quoted path after in:."
            }
            parts.explicitIntent = true
        }

        while index < tokens.count {
            let token = tokens[index]
            let raw = token.value
            let lower = fold(raw).lowercased()
            let nextValue = index + 1 < tokens.count ? tokens[index + 1].value : nil

            // Quotes make the contents a name phrase. Keep words such as
            // "The File" in the name query, while still parsing in:"path".
            if token.quoted && !lower.hasPrefix("in:") && !isPath(raw) {
                parts.nameWords.append(contentsOf: raw.split(whereSeparator: { $0.isWhitespace }).map(String.init))
                index += 1
                continue
            }

            if lower.hasPrefix("kind:") || lower.hasPrefix("type:") {
                let value = String(raw.drop { $0 != ":" }.dropFirst())
                if let kind = kind(for: value) {
                    setKind(kind)
                } else {
                    parts.error = "Unknown file kind: \(value)."
                }
                parts.explicitIntent = true
                index += 1
                continue
            }

            if lower.hasPrefix("modified:") || lower.hasPrefix("date:") {
                let value = String(raw.drop { $0 != ":" }.dropFirst())
                if let modified = modified(for: value) {
                    setModified(modified)
                } else {
                    parts.error = "Use today, yesterday, or week after modified:."
                }
                parts.explicitIntent = true
                index += 1
                continue
            }

            if lower.hasPrefix("in:") {
                let value = String(raw.drop { $0 != ":" }.dropFirst())
                if value.isEmpty, let nextValue {
                    setScope(nextValue)
                    index += 2
                } else {
                    setScope(value)
                    index += 1
                }
                continue
            }

            if lower == "in" || lower == "from" || lower == "within" {
                let recognized = nextValue.map(isScopeValue) ?? false
                guard recognized || explicitFileContext else {
                    index += 1
                    continue
                }
                parts.explicitIntent = true
                explicitFileContext = true
                if let nextValue {
                    setScope(nextValue)
                    index += 2
                } else {
                    parts.error = "Add Downloads, Desktop, Documents, or a quoted path after \(raw)."
                    index += 1
                }
                continue
            }

            if lower == "modified" || lower == "changed" || lower == "updated" {
                parts.explicitIntent = true
                if let nextValue, let modified = modified(for: nextValue) {
                    setModified(modified)
                    index += 2
                } else {
                    parts.error = "Use today, yesterday, or week after modified."
                    index += 1
                }
                continue
            }

            if let kind = kind(for: lower), isKindPhrase(lower) {
                guard explicitFileContext || !ambiguousKindPhrases.contains(lower) else {
                    parts.nameWords.append(raw)
                    index += 1
                    continue
                }
                setKind(kind)
                parts.explicitIntent = true
                explicitFileContext = true
                index += 1
                continue
            }

            if let modified = modified(for: lower), isDatePhrase(lower) {
                setModified(modified)
                parts.explicitIntent = true
                index += 1
                continue
            }

            if (lower == "downloads" || lower == "desktop"), parts.scope == nil, parts.scopePath == nil {
                setScope(lower)
                explicitFileContext = true
                index += 1
                continue
            }

            if isPath(raw) {
                if parts.explicitPath == nil {
                    parts.explicitPath = raw
                } else {
                    parts.nameWords.append(raw)
                }
                parts.explicitIntent = true
                index += 1
                continue
            }

            if lower == "folder" || lower == "folders" {
                setKind(.folder)
                parts.explicitIntent = true
                index += 1
                continue
            }

            if commandWords.contains(lower) {
                if lower == "find" || lower == "locate" || lower == "list" || lower == "file" || lower == "files" {
                    parts.explicitIntent = true
                    explicitFileContext = true
                }
                index += 1
                continue
            }

            // A quoted non-path value is a name phrase, not a shell command.
            parts.nameWords.append(contentsOf: raw.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            index += 1
        }

        parts.nameWords = parts.nameWords.filter { !$0.isEmpty }
        return parts
    }

    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var quoted = false
        var inQuotes = false
        var quoteCharacter: Character?

        func flush() {
            guard !current.isEmpty else { return }
            result.append(Token(value: current, quoted: quoted))
            current = ""
            quoted = false
        }

        for character in text {
            if let closingQuote = quoteCharacter, character == closingQuote {
                inQuotes.toggle()
                quoteCharacter = nil
                quoted = true
            } else if (character == "\"" || character == "'") && !inQuotes {
                inQuotes = true
                quoteCharacter = character
                quoted = true
            } else if character.isWhitespace && !inQuotes {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }

    private static func isPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~/") || value.lowercased().hasPrefix("file://")
    }

    private static func isScopeValue(_ value: String) -> Bool {
        let folded = fold(value).lowercased()
        return Scope(rawValue: folded) != nil || isPath(value)
    }

    private static func kind(for value: String) -> Kind? {
        let value = fold(value).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "pdf", "pdfs": return .pdf
        case "image", "images", "photo", "photos", "picture", "pictures": return .image
        case "document", "documents", "doc", "docs": return .document
        case "folder", "folders", "directory", "directories": return .folder
        case "audio", "audios", "music", "song", "songs": return .audio
        case "video", "videos", "movie", "movies": return .video
        default: return nil
        }
    }

    private static func modified(for value: String) -> Modified? {
        switch fold(value).lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "today": return .today
        case "yesterday", "yesterdays": return .yesterday
        case "week", "thisweek", "this-week": return .week
        default: return nil
        }
    }

    private static func isKindPhrase(_ value: String) -> Bool {
        ["pdf", "pdfs", "image", "images", "photo", "photos", "picture", "pictures", "document", "documents", "doc", "docs", "audio", "audios", "music", "song", "songs", "video", "videos", "movie", "movies"].contains(value)
    }

    private static let ambiguousKindPhrases: Set<String> = [
        "music", "audio", "photo", "photos", "picture", "pictures", "video", "movie", "movies"
    ]

    private static func isDatePhrase(_ value: String) -> Bool {
        ["today", "yesterday", "yesterdays", "week", "thisweek", "this-week"].contains(value)
    }

    private static func makeSummary(
        nameQuery: String,
        kind: Kind?,
        modified: Modified?,
        scope: Scope?,
        scopePath: String?,
        explicitPath: String?,
        error: String?
    ) -> String {
        if let error { return "Invalid file search · \(error)" }
        var values: [String] = []
        if let kind { values.append(kind == .folder ? "Folders" : kind.rawValue.uppercased() + " files") }
        if let modified {
            values.append("modified " + modified.rawValue)
        }
        if let scope { values.append("in " + scope.rawValue.capitalized) }
        if let scopePath { values.append("in " + scopePath) }
        if let explicitPath { values.append(explicitPath) }
        if !nameQuery.isEmpty { values.append("named " + nameQuery) }
        return values.isEmpty ? "Files" : values.joined(separator: " · ")
    }
}
