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
            case .image: return ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "avif", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]
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
        case lastWeek = "last-week"
        case month
        case lastMonth = "last-month"

        public var title: String {
            switch self {
            case .today: return "today"
            case .yesterday: return "yesterday"
            case .week: return "this week"
            case .lastWeek: return "last week"
            case .month: return "this month"
            case .lastMonth: return "last month"
            }
        }
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
        case .lastWeek:
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: previous)
        case .month:
            return calendar.dateInterval(of: .month, for: now)
        case .lastMonth:
            guard let previous = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: previous)
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
            let allWordsMatch = nameQuery.split(separator: " ").allSatisfy { word in
                let folded = Self.fold(String(word))
                // "screenshots" still finds "Screenshot 2026-09-23.png".
                let singular = folded.count > 3 && folded.hasSuffix("s") ? String(folded.dropLast()) : folded
                return foldedName.contains(folded) || foldedName.contains(singular)
            }
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
        "recent", "latest", "newest", "my", "i", "all", "any", "some", "that", "which", "were", "was", "from", "since", "made", "saved"
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
        // Keep ambiguous words such as "Music", "Desktop", "Docs", and
        // "Today" available for normal launcher matching ("GitHub Desktop",
        // "Google Docs"). Other file context gives those words file meaning.
        var explicitFileContext = hasFileContext(tokens)
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
                    parts.error = "Use today, yesterday, week, last-week, month, or last-month after modified:."
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

            // "this week", "last week", "past month", "previous month".
            if ["this", "last", "past", "previous"].contains(lower), let nextValue,
               let modified = relativeDate(lower, fold(nextValue).lowercased()) {
                guard explicitFileContext || parts.kind != nil else {
                    parts.nameWords.append(raw)
                    index += 1
                    continue
                }
                setModified(modified)
                parts.explicitIntent = true
                explicitFileContext = true
                index += 2
                continue
            }

            if lower == "in" || lower == "from" || lower == "within" {
                let recognized = nextValue.map(isScopeValue) ?? false
                guard recognized || explicitFileContext else {
                    index += 1
                    continue
                }
                // A connector before a date or filler word, such as "from last week", is not a folder.
                if !recognized, let nextValue, !nextValue.hasPrefix("\"") {
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
                explicitFileContext = true
                if let nextValue, let modified = modified(for: nextValue) {
                    setModified(modified)
                    index += 2
                } else if let nextValue, ["this", "last", "past", "previous", "in", "from", "since", "on"].contains(fold(nextValue).lowercased()) {
                    index += 1
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

            if explicitFileContext, let modified = modified(for: lower), isDatePhrase(lower) {
                setModified(modified)
                parts.explicitIntent = true
                index += 1
                continue
            }

            if explicitFileContext, lower == "downloads" || lower == "desktop", parts.scope == nil, parts.scopePath == nil {
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

    private static let contextWords: Set<String> = [
        "find", "locate", "list", "file", "files", "folder", "folders", "recent", "latest", "newest", "modified", "changed", "updated"
    ]

    /// Finds words that make a request about files, without counting the
    /// folder, date, and ambiguous kind words that the context unlocks.
    private static func hasFileContext(_ tokens: [Token]) -> Bool {
        for (index, token) in tokens.enumerated() where !token.quoted {
            let value = fold(token.value).lowercased()
            if contextWords.contains(value) || isPath(token.value) { return true }
            if isKindPhrase(value) && !ambiguousKindPhrases.contains(value) { return true }
            if ["kind:", "type:", "modified:", "date:", "in:"].contains(where: value.hasPrefix) { return true }
            if ["in", "from", "within"].contains(value), index + 1 < tokens.count, isScopeValue(tokens[index + 1].value) {
                return true
            }
        }
        return false
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

        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            // An apostrophe opens a quote only at a token start ("'my cv'",
            // in:'~/x') and closes one only at a token end, so "ryan's" stays a word.
            let opensSingle = current.isEmpty || current.hasSuffix(":")
            let closesSingle = next == nil || next!.isWhitespace
            if let closingQuote = quoteCharacter, character == closingQuote, closingQuote == "\"" || closesSingle {
                inQuotes.toggle()
                quoteCharacter = nil
                quoted = true
            } else if (character == "\"" || (character == "'" && opensSingle)) && !inQuotes {
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
        // A lone "/" is division in "100 / 4", not the root folder.
        (value.hasPrefix("/") && value.count > 1) || value.hasPrefix("~/") || value.lowercased().hasPrefix("file://")
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
        case "last-week", "lastweek": return .lastWeek
        case "month", "thismonth", "this-month": return .month
        case "last-month", "lastmonth": return .lastMonth
        default: return nil
        }
    }

    private static func relativeDate(_ qualifier: String, _ unit: String) -> Modified? {
        let last = qualifier != "this"
        switch unit {
        case "week": return last ? .lastWeek : .week
        case "month": return last ? .lastMonth : .month
        default: return nil
        }
    }

    private static func isKindPhrase(_ value: String) -> Bool {
        ["pdf", "pdfs", "image", "images", "photo", "photos", "picture", "pictures", "document", "documents", "doc", "docs", "audio", "audios", "music", "song", "songs", "video", "videos", "movie", "movies"].contains(value)
    }

    private static let ambiguousKindPhrases: Set<String> = [
        "music", "audio", "photo", "photos", "picture", "pictures", "video", "movie", "movies",
        "document", "documents", "doc", "docs"
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
            values.append("modified " + modified.title)
        }
        if let scope { values.append("in " + scope.rawValue.capitalized) }
        if let scopePath { values.append("in " + scopePath) }
        if let explicitPath { values.append(explicitPath) }
        if !nameQuery.isEmpty { values.append("named " + nameQuery) }
        return values.isEmpty ? "Files" : values.joined(separator: " · ")
    }
}
