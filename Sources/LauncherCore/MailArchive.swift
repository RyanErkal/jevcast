import CryptoKit
import Foundation

/// The two interchange formats Jevcast can import and export without contacting a provider.
public enum MailArchiveFormat: String, CaseIterable, Codable, Sendable {
    case eml
    case mbox

    public init(fileExtension: String) throws {
        switch fileExtension.lowercased() {
        case "eml": self = .eml
        case "mbox": self = .mbox
        default: throw MailArchiveError.unsupportedFormat
        }
    }
}

/// Limits are deliberately finite because archive files come from outside the app.
public struct MailArchiveLimits: Equatable, Sendable {
    public var maxInputBytes: Int
    public var maxMessageBytes: Int
    public var maxMessages: Int
    public var maxIndexBytes: Int

    public init(maxInputBytes: Int = 128 * 1024 * 1024,
                maxMessageBytes: Int = 25 * 1024 * 1024,
                maxMessages: Int = 10_000,
                maxIndexBytes: Int = 16 * 1024 * 1024) {
        self.maxInputBytes = max(1, maxInputBytes)
        self.maxMessageBytes = max(1, maxMessageBytes)
        self.maxMessages = max(1, maxMessages)
        self.maxIndexBytes = max(1, maxIndexBytes)
    }

    public static let `default` = MailArchiveLimits()
}

public enum MailArchiveError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case unsafeSource
    case unsafeDestination
    case sourceTooLarge
    case messageTooLarge
    case malformedArchive
    case malformedMessage
    case corruptIndex
    case corruptMessage
    case sourceChanged
    case destinationExists
    case noMessages
    case storageFailure

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Choose an .eml or .mbox file."
        case .unsafeSource: return "This mail file cannot be read safely. Choose a regular file that is not a symbolic link."
        case .unsafeDestination: return "That export location cannot be used safely. Choose a normal local folder."
        case .sourceTooLarge: return "This mail file is larger than Jevcast's import limit."
        case .messageTooLarge: return "A message is larger than Jevcast's import limit."
        case .malformedArchive: return "This archive has no valid mail messages."
        case .malformedMessage: return "A message is not a valid RFC 5322 mail message."
        case .corruptIndex: return "The local mail archive index is damaged. Jevcast left it unchanged."
        case .corruptMessage: return "The archived message is damaged or changed."
        case .sourceChanged: return "The source file changed after its preview. Preview it again before importing."
        case .destinationExists: return "That file already exists. Confirm replacement in the save panel first."
        case .noMessages: return "There are no messages to export."
        case .storageFailure: return "The local mail archive could not be saved."
        }
    }
}

public enum MailArchiveIssueKind: String, Codable, Sendable {
    case malformedMessage
    case emptyMessage
    case messageTooLarge
    case duplicate
    case malformedArchive
}

/// A non-sensitive preview error. Source paths and message contents are not retained here.
public struct MailArchiveIssue: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let messageIndex: Int?
    public let kind: MailArchiveIssueKind
    public let detail: String

    public init(messageIndex: Int? = nil, kind: MailArchiveIssueKind, detail: String) {
        self.id = UUID()
        self.messageIndex = messageIndex
        self.kind = kind
        self.detail = detail
    }
}

public struct MailArchiveAttachmentSummary: Codable, Equatable, Sendable, Hashable {
    public let name: String
    public let mimeType: String
    public let size: Int

    public init(name: String, mimeType: String, size: Int) {
        self.name = name
        self.mimeType = mimeType
        self.size = size
    }
}

/// Metadata kept in the local index. The message itself is always read from its raw `.eml` file.
public struct MailArchiveMessage: Codable, Equatable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let digest: String
    public let byteCount: Int
    public let subject: String
    public let sender: String
    public let recipients: String
    public let date: Date?
    public let importedAt: Date
    public let attachments: [MailArchiveAttachmentSummary]

    public init(id: UUID = UUID(), digest: String, byteCount: Int, subject: String, sender: String,
                recipients: String, date: Date?, importedAt: Date = Date(),
                attachments: [MailArchiveAttachmentSummary] = []) {
        self.id = id
        self.digest = digest
        self.byteCount = byteCount
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.date = date
        self.importedAt = importedAt
        self.attachments = attachments
    }
}

public struct MailArchivePreviewMessage: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let digest: String
    public let byteCount: Int
    public let subject: String
    public let sender: String
    public let recipients: String
    public let date: Date?
    public let attachments: [MailArchiveAttachmentSummary]
    public let duplicate: Bool

    public init(id: UUID = UUID(), digest: String, byteCount: Int, subject: String, sender: String,
                recipients: String, date: Date?, attachments: [MailArchiveAttachmentSummary], duplicate: Bool) {
        self.id = id
        self.digest = digest
        self.byteCount = byteCount
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.date = date
        self.attachments = attachments
        self.duplicate = duplicate
    }
}

public struct MailArchivePreview: Equatable, Sendable {
    public let sourceName: String
    public let format: MailArchiveFormat
    public let sourceByteCount: Int
    public let sourceDigest: String
    public let messages: [MailArchivePreviewMessage]
    public let duplicateCount: Int
    public let errors: [MailArchiveIssue]

    public init(sourceName: String, format: MailArchiveFormat, sourceByteCount: Int, sourceDigest: String,
                messages: [MailArchivePreviewMessage], duplicateCount: Int, errors: [MailArchiveIssue]) {
        self.sourceName = sourceName
        self.format = format
        self.sourceByteCount = sourceByteCount
        self.sourceDigest = sourceDigest
        self.messages = messages
        self.duplicateCount = duplicateCount
        self.errors = errors
    }
}

public struct MailArchiveProgress: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable { case reading, writing, finished }
    public let stage: Stage
    public let processed: Int
    public let total: Int
    public let bytesProcessed: Int
    public let totalBytes: Int

    public init(stage: Stage, processed: Int, total: Int, bytesProcessed: Int, totalBytes: Int) {
        self.stage = stage
        self.processed = processed
        self.total = total
        self.bytesProcessed = bytesProcessed
        self.totalBytes = totalBytes
    }
}

public struct MailArchiveImportResult: Equatable, Sendable {
    public let imported: [MailArchiveMessage]
    public let duplicateCount: Int
    public let errors: [MailArchiveIssue]

    public init(imported: [MailArchiveMessage], duplicateCount: Int, errors: [MailArchiveIssue]) {
        self.imported = imported
        self.duplicateCount = duplicateCount
        self.errors = errors
    }
}

public struct MailArchiveExportResult: Equatable, Sendable {
    public let messageCount: Int
    public let byteCount: Int
    public let destination: URL

    public init(messageCount: Int, byteCount: Int, destination: URL) {
        self.messageCount = messageCount
        self.byteCount = byteCount
        self.destination = destination
    }
}

/// A local-only, raw-message archive. It never talks to IMAP, SMTP, Apple Mail, or a provider.
/// The index and raw messages are owner-only and use no-follow, atomic file operations.
public final class MailArchiveStore: @unchecked Sendable {
    public let root: URL
    public let limits: MailArchiveLimits

    private struct Index: Codable {
        let version: Int
        let messages: [MailArchiveMessage]
    }

    private let indexURL: URL
    private let messagesURL: URL
    private let lock = NSLock()
    private var records: [MailArchiveMessage]

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jevcast", isDirectory: true)
            .appendingPathComponent("MailArchive", isDirectory: true)
    }

    public init(root: URL = MailArchiveStore.defaultRoot, limits: MailArchiveLimits = .default) throws {
        self.root = root.standardizedFileURL
        self.limits = limits
        self.indexURL = self.root.appendingPathComponent("index.json", isDirectory: false)
        self.messagesURL = self.root.appendingPathComponent("Messages", isDirectory: true)
        self.records = []
        do {
            try SecureFile.ensureParents(of: indexURL)
            try SecureFile.ensureDirectory(self.root)
            try SecureFile.ensureDirectory(self.messagesURL)
        } catch { throw MailArchiveError.storageFailure }
        do {
            if let data = try SecureFile.read(indexURL, maxBytes: limits.maxIndexBytes) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let index = try decoder.decode(Index.self, from: data)
                guard index.version == 1, Self.valid(index.messages) else { throw MailArchiveError.corruptIndex }
                self.records = index.messages
            } else {
                try Self.save(records: [], to: indexURL)
            }
        } catch let error as MailArchiveError { throw error }
        catch { throw MailArchiveError.corruptIndex }
    }

    public var count: Int { lock.withLock { records.count } }

    public func allMessages() -> [MailArchiveMessage] {
        lock.withLock { records }
    }

    public func messages(matching query: String) -> [MailArchiveMessage] {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !folded.isEmpty else { return allMessages() }
        // The index keeps headers for fast list rendering. Body search is still local and bounded:
        // each candidate is read through `rawMessage`, which enforces the message size limit and
        // rejects changed or symlinked files.
        return allMessages().filter { record in
            if [record.subject, record.sender, record.recipients].contains(where: {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(folded)
            }) { return true }
            guard let raw = try? rawMessage(for: record.id), let parsed = MIMEMessage.parse(raw) else { return false }
            return parsed.readableText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(folded)
        }
    }

    public func rawMessage(for message: MailArchiveMessage) throws -> Data {
        guard lock.withLock({ records.contains(message) }) else { throw MailArchiveError.corruptMessage }
        return try rawMessage(for: message.id)
    }

    public func rawMessage(for id: UUID) throws -> Data {
        let record = lock.withLock { records.first { $0.id == id } }
        guard let record else { throw MailArchiveError.corruptMessage }
        let url = rawURL(for: id)
        do {
            guard let data = try SecureFile.read(url, maxBytes: limits.maxMessageBytes),
                  Self.digest(data) == record.digest,
                  MIMEMessage.parse(data) != nil else { throw MailArchiveError.corruptMessage }
            return data
        } catch let error as MailArchiveError { throw error }
        catch { throw MailArchiveError.corruptMessage }
    }

    /// Preview is intentionally separate from import so the UI can show duplicates and errors first.
    public func preview(url: URL, progress: ((MailArchiveProgress) -> Void)? = nil) throws -> MailArchivePreview {
        let source = try readSource(url, progress: progress)
        let format = try MailArchiveFormat(fileExtension: url.pathExtension)
        let candidates = Self.parse(source.data, format: format, limits: limits)
        let known = Set(lock.withLock { records.map(\.digest) })
        var seen = known
        var messages: [MailArchivePreviewMessage] = []
        var duplicates = 0
        var errors = candidates.errors
        for (index, candidate) in candidates.messages.enumerated() {
            let duplicate = !seen.insert(candidate.digest).inserted
            if duplicate {
                duplicates += 1
                errors.append(MailArchiveIssue(messageIndex: index, kind: .duplicate, detail: "This message is already in the archive."))
            }
            messages.append(MailArchivePreviewMessage(digest: candidate.digest, byteCount: candidate.raw.count,
                                                      subject: candidate.message.header("Subject") ?? "",
                                                      sender: Self.addressHeader(candidate.message.header("From")),
                                                      recipients: candidate.message.header("To") ?? "",
                                                      date: Self.date(candidate.message.header("Date")),
                                                      attachments: candidate.message.attachments.map { .init(name: $0.name, mimeType: $0.mimeType, size: $0.size) },
                                                      duplicate: duplicate))
        }
        guard !messages.isEmpty || !errors.isEmpty else { throw MailArchiveError.malformedArchive }
        return MailArchivePreview(sourceName: url.lastPathComponent, format: format, sourceByteCount: source.data.count,
                                  sourceDigest: Self.digest(source.data), messages: messages, duplicateCount: duplicates, errors: errors)
    }

    /// Imports the same source that was previewed. A changed file is rejected before any write.
    @discardableResult
    public func importArchive(url: URL, preview: MailArchivePreview? = nil,
                              progress: ((MailArchiveProgress) -> Void)? = nil) throws -> MailArchiveImportResult {
        let source = try readSource(url, progress: progress)
        let format = try MailArchiveFormat(fileExtension: url.pathExtension)
        if let preview, preview.format != format || preview.sourceByteCount != source.data.count || preview.sourceDigest != Self.digest(source.data) {
            throw MailArchiveError.sourceChanged
        }
        let candidates = Self.parse(source.data, format: format, limits: limits)
        var errors = candidates.errors
        var imported: [MailArchiveMessage] = []
        var duplicates = 0
        lock.lock()
        defer { lock.unlock() }
        var known = Set(records.map(\.digest))
        for (index, candidate) in candidates.messages.enumerated() {
            if known.contains(candidate.digest) {
                duplicates += 1
                errors.append(MailArchiveIssue(messageIndex: index, kind: .duplicate, detail: "This message is already in the archive."))
                progress?(MailArchiveProgress(stage: .writing, processed: imported.count, total: candidates.messages.count,
                                               bytesProcessed: source.data.count, totalBytes: source.data.count))
                continue
            }
            let item = MailArchiveMessage(digest: candidate.digest, byteCount: candidate.raw.count,
                                          subject: candidate.message.header("Subject") ?? "",
                                          sender: Self.addressHeader(candidate.message.header("From")),
                                          recipients: candidate.message.header("To") ?? "",
                                          date: Self.date(candidate.message.header("Date")),
                                          attachments: candidate.message.attachments.map { .init(name: $0.name, mimeType: $0.mimeType, size: $0.size) })
            do {
                try SecureFile.write(candidate.raw, to: rawURL(for: item.id))
                records.append(item)
                known.insert(candidate.digest)
                imported.append(item)
            } catch {
                errors.append(MailArchiveIssue(messageIndex: index, kind: .malformedArchive, detail: "The message could not be saved."))
            }
            progress?(MailArchiveProgress(stage: .writing, processed: imported.count, total: candidates.messages.count,
                                          bytesProcessed: source.data.count, totalBytes: source.data.count))
        }
        if !imported.isEmpty {
            do { try Self.save(records: records, to: indexURL) }
            catch {
                // Do not replace a valid index with an incomplete or corrupt one. Raw files remain
                // unreferenced and can be safely ignored on a later archive repair.
                records.removeLast(imported.count)
                throw MailArchiveError.storageFailure
            }
        }
        progress?(MailArchiveProgress(stage: .finished, processed: imported.count, total: candidates.messages.count,
                                      bytesProcessed: source.data.count, totalBytes: source.data.count))
        return MailArchiveImportResult(imported: imported, duplicateCount: duplicates, errors: errors)
    }

    /// Exports archived records. `ids == nil` means all archived messages.
    @discardableResult
    public func export(ids: [UUID]? = nil, format: MailArchiveFormat, to destination: URL,
                       overwrite: Bool = false, progress: ((MailArchiveProgress) -> Void)? = nil) throws -> MailArchiveExportResult {
        let chosen = lock.withLock { ids.map { wanted in records.filter { wanted.contains($0.id) } } ?? records }
        let raw = try chosen.map { try rawMessage(for: $0.id) }
        return try exportNative(rawMessages: raw, format: format, to: destination, overwrite: overwrite, progress: progress)
    }

    /// Exports selected native messages supplied by the root. The bytes never enter the archive.
    /// The caller may pass `overwrite: true` only after its normal save panel confirms replacement.
    @discardableResult
    public func exportNative(rawMessages: [Data], format: MailArchiveFormat, to destination: URL,
                             overwrite: Bool = false, progress: ((MailArchiveProgress) -> Void)? = nil) throws -> MailArchiveExportResult {
        guard !rawMessages.isEmpty else { throw MailArchiveError.noMessages }
        guard rawMessages.allSatisfy({ $0.count <= limits.maxMessageBytes && MIMEMessage.parse($0) != nil }) else {
            throw MailArchiveError.malformedMessage
        }
        if format == .eml, rawMessages.count != 1 { throw MailArchiveError.unsupportedFormat }
        let target = destination.standardizedFileURL
        if FileManager.default.fileExists(atPath: target.path) {
            guard overwrite else { throw MailArchiveError.destinationExists }
            guard let st = SafeFS.lstatPath(target.path), st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
                throw MailArchiveError.unsafeDestination
            }
        }
        do { try SecureFile.ensureParents(of: target) } catch { throw MailArchiveError.unsafeDestination }
        let output: Data
        switch format {
        case .eml: output = rawMessages[0]
        case .mbox: output = Self.makeMbox(rawMessages)
        }
        do { try SecureFile.write(output, to: target) } catch { throw MailArchiveError.storageFailure }
        progress?(MailArchiveProgress(stage: .finished, processed: rawMessages.count, total: rawMessages.count,
                                      bytesProcessed: output.count, totalBytes: output.count))
        return MailArchiveExportResult(messageCount: rawMessages.count, byteCount: output.count, destination: target)
    }

    /// A safe single-component filename for save-panel defaults and attachment controls.
    public static func safeFilename(_ name: String, fallback: String = "mail") -> String {
        let normalized = name.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\\", with: "/")
        var component = normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let scalars = component.unicodeScalars.filter {
            let value = $0.value
            let bidiOverride = (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
            return value >= 0x20 && value != 0x7F && value != 0 && !bidiOverride
        }
        component = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if component.isEmpty || component == "." || component == ".." { component = fallback }
        return String(component.prefix(240))
    }

    /// Saves a decoded attachment through the same no-follow, owner-only path checks as export.
    /// The caller may pass `overwrite: true` only after its normal save panel confirms replacement.
    public func saveAttachmentData(_ data: Data, to destination: URL, overwrite: Bool = false) throws {
        guard destination.isFileURL else { throw MailArchiveError.unsafeDestination }
        let target = destination.standardizedFileURL
        if FileManager.default.fileExists(atPath: target.path) {
            guard overwrite else { throw MailArchiveError.destinationExists }
            guard let st = SafeFS.lstatPath(target.path), st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
                throw MailArchiveError.unsafeDestination
            }
        }
        do { try SecureFile.ensureParents(of: target); try SecureFile.write(data, to: target) }
        catch { throw MailArchiveError.unsafeDestination }
    }

    // MARK: Storage and parsing

    private struct Candidate {
        let raw: Data
        let message: MIMEMessage
        var digest: String { MailArchiveStore.digest(raw) }
    }

    private struct ParsedCandidates { let messages: [Candidate]; let errors: [MailArchiveIssue] }
    private struct Source { let data: Data }

    private func rawURL(for id: UUID) -> URL {
        messagesURL.appendingPathComponent(id.uuidString + ".eml", isDirectory: false)
    }

    private func readSource(_ url: URL, progress: ((MailArchiveProgress) -> Void)?) throws -> Source {
        guard url.isFileURL else { throw MailArchiveError.unsafeSource }
        let ext = url.pathExtension.lowercased()
        guard ext == "eml" || ext == "mbox" else { throw MailArchiveError.unsupportedFormat }
        guard let stat = SafeFS.lstatPath(url.standardizedFileURL.path), stat.st_mode & S_IFMT == S_IFREG,
              stat.st_nlink == 1 else { throw MailArchiveError.unsafeSource }
        progress?(MailArchiveProgress(stage: .reading, processed: 0, total: 1, bytesProcessed: 0, totalBytes: 0))
        do {
            guard let data = try SecureFile.read(url.standardizedFileURL, maxBytes: limits.maxInputBytes) else { throw MailArchiveError.unsafeSource }
            progress?(MailArchiveProgress(stage: .reading, processed: 1, total: 1, bytesProcessed: data.count, totalBytes: data.count))
            return Source(data: data)
        } catch let error as MailArchiveError { throw error }
        catch let error as AutomationStoreError {
            switch error {
            case .tooLarge: throw MailArchiveError.sourceTooLarge
            default: throw MailArchiveError.unsafeSource
            }
        }
        catch { throw MailArchiveError.sourceTooLarge }
    }

    private static func valid(_ messages: [MailArchiveMessage]) -> Bool {
        var ids = Set<UUID>(), digests = Set<String>()
        return messages.allSatisfy { item in
            !item.digest.isEmpty && item.byteCount >= 0 && ids.insert(item.id).inserted && digests.insert(item.digest).inserted
        }
    }

    private static func save(records: [MailArchiveMessage], to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Index(version: 1, messages: records))
        try SecureFile.write(data, to: url)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parse(_ data: Data, format: MailArchiveFormat, limits: MailArchiveLimits) -> ParsedCandidates {
        switch format {
        case .eml: return parseMessages([data], limits: limits, mbox: false)
        case .mbox:
            let split = splitMbox(data)
            return parseMessages(split.messages, limits: limits, mbox: true, initialErrors: split.errors)
        }
    }

    private static func parseMessages(_ raws: [Data], limits: MailArchiveLimits, mbox: Bool,
                                      initialErrors: [MailArchiveIssue] = []) -> ParsedCandidates {
        var valid: [Candidate] = [], errors = initialErrors
        for (index, raw) in raws.enumerated() {
            guard !raw.isEmpty else {
                errors.append(MailArchiveIssue(messageIndex: index, kind: .emptyMessage, detail: "The message is empty.")); continue
            }
            guard raw.count <= limits.maxMessageBytes else {
                errors.append(MailArchiveIssue(messageIndex: index, kind: .messageTooLarge, detail: "The message exceeds the import limit.")); continue
            }
            guard let message = MIMEMessage.parse(raw) else {
                errors.append(MailArchiveIssue(messageIndex: index, kind: .malformedMessage, detail: "The message could not be parsed.")); continue
            }
            valid.append(Candidate(raw: raw, message: message))
            if valid.count >= limits.maxMessages { break }
        }
        if raws.count > limits.maxMessages {
            errors.append(MailArchiveIssue(kind: .malformedArchive, detail: "The archive contains too many messages."))
        }
        if !mbox && valid.isEmpty && errors.isEmpty { errors.append(MailArchiveIssue(kind: .malformedMessage, detail: "The message could not be parsed.")) }
        return ParsedCandidates(messages: valid, errors: errors)
    }

    private static func splitMbox(_ data: Data) -> (messages: [Data], errors: [MailArchiveIssue]) {
        let bytes = [UInt8](data)
        var starts: [(start: Int, end: Int)] = []
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let contentEnd = lineEnd > lineStart && bytes[lineEnd - 1] == 0x0D ? lineEnd - 1 : lineEnd
            if contentEnd - lineStart >= 5,
               bytes[lineStart] == 0x46, bytes[lineStart + 1] == 0x72, bytes[lineStart + 2] == 0x6F,
               bytes[lineStart + 3] == 0x6D, bytes[lineStart + 4] == 0x20 {
                starts.append((lineStart, min(bytes.count, lineEnd + (lineEnd < bytes.count ? 1 : 0))))
            }
            lineStart = lineEnd < bytes.count ? lineEnd + 1 : bytes.count
        }
        guard let first = starts.first else {
            return ([], [MailArchiveIssue(kind: .malformedArchive, detail: "The mbox has no From delimiter." )])
        }
        var errors: [MailArchiveIssue] = []
        if first.start > 0 { errors.append(MailArchiveIssue(kind: .malformedArchive, detail: "Bytes before the first From delimiter were ignored.")) }
        var messages: [Data] = []
        for index in starts.indices {
            let from = starts[index].end
            let to = index + 1 < starts.count ? starts[index + 1].start : bytes.count
            guard to >= from else { continue }
            var raw = Data(bytes[from..<to])
            raw = removeStructuralLineEnding(raw)
            raw = unescapeMbox(raw)
            messages.append(raw)
        }
        return (messages, errors)
    }

    private static func removeStructuralLineEnding(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        if bytes.last == 0x0A {
            bytes.removeLast()
            if bytes.last == 0x0D { bytes.removeLast() }
        }
        return Data(bytes)
    }

    private static func unescapeMbox(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []; output.reserveCapacity(bytes.count)
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = bytes[lineStart..<contentEnd]
            var prefix = 0
            while prefix < line.count, line[line.index(line.startIndex, offsetBy: prefix)] == 0x3E { prefix += 1 }
            if prefix > 0 {
                let from = line.index(line.startIndex, offsetBy: prefix)
                if line.distance(from: from, to: line.endIndex) >= 5,
                   Array(line[from..<line.index(from, offsetBy: 5)]) == [0x46, 0x72, 0x6F, 0x6D, 0x20] {
                    output.append(contentsOf: bytes[lineStart..<(lineStart + prefix - 1)])
                    output.append(contentsOf: bytes[(lineStart + prefix)..<contentEnd])
                } else { output.append(contentsOf: bytes[lineStart..<contentEnd]) }
            } else { output.append(contentsOf: bytes[lineStart..<contentEnd]) }
            if contentEnd < lineEnd { output.append(0x0D) }
            if lineEnd < bytes.count { output.append(0x0A) }
            lineStart = lineEnd < bytes.count ? lineEnd + 1 : bytes.count
        }
        return Data(output)
    }

    private static func makeMbox(_ raws: [Data]) -> Data {
        var output = Data()
        for raw in raws {
            output.append(Data("From - Jevcast Archive\n".utf8))
            output.append(escapeMbox(raw))
            // One structural LF is always appended. Import removes only this LF, preserving
            // whether the original message itself ended with LF or CRLF.
            output.append(0x0A)
        }
        return output
    }

    private static func escapeMbox(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []; output.reserveCapacity(bytes.count)
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = Array(bytes[lineStart..<contentEnd])
            var prefix = 0
            while prefix < line.count, line[prefix] == 0x3E { prefix += 1 }
            if line.count - prefix >= 5, Array(line[prefix..<prefix + 5]) == [0x46, 0x72, 0x6F, 0x6D, 0x20] { output.append(0x3E) }
            output.append(contentsOf: line)
            if lineEnd < bytes.count { output.append(contentsOf: bytes[contentEnd...lineEnd]) }
            lineStart = lineEnd < bytes.count ? lineEnd + 1 : bytes.count
        }
        return Data(output)
    }

    private static func addressHeader(_ value: String?) -> String {
        guard let value else { return "" }
        if let start = value.lastIndex(of: "<"), let end = value[start...].firstIndex(of: ">"), start < end {
            return String(value[value.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss ZZZ"
        return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? ISO8601DateFormatter().date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
