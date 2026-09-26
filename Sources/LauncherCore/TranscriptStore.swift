import Foundation

/// One dictation, as stored. Text only; audio is never kept.
public struct Transcript: Codable, Equatable, Sendable {
    public let text: String
    public let date: Date
    /// Seconds the key was held.
    public let duration: TimeInterval
    /// Bundle ID of the app the text went to, when known.
    public let target: String?
    /// "apple-speech", or "apple-speech+luna" when Quill cleaned the text (see `QuillStorageKeys.transcriptEngineSuffix`).
    public let engine: String
    public init(text: String, date: Date, duration: TimeInterval, target: String?, engine: String) {
        self.text = text; self.date = date; self.duration = duration; self.target = target; self.engine = engine
    }
}

/// How long dictation history is kept.
public enum DictationRetention: String, CaseIterable, Codable, Sendable {
    case all, days30, none
    public var title: String {
        switch self { case .all: return "Keep all"; case .days30: return "30 days"; case .none: return "Don't keep" }
    }
    var maxAge: TimeInterval? {
        switch self { case .all: return nil; case .days30: return 30 * 86_400; case .none: return 0 }
    }
}

/// Dictation history as JSON Lines, one file per day, such as "2026-09-24.jsonl".
public struct TranscriptStore: Sendable {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    /// Adds one entry, unless the retention keeps none.
    public func append(_ transcript: Transcript, retention: DictationRetention) throws {
        guard retention != .none else { return }
        // Only this user may read the history: the file is created 0600, never wider for a moment.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(Self.dayName(transcript.date) + ".jsonl")
        var line = try Self.encoder().encode(transcript)
        line.append(0x0A)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        // A line cut short, such as by a crash, must not swallow this entry.
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
        }
        // O_APPEND writes at the end whatever the offset.
        try handle.write(contentsOf: line)
    }

    /// Every entry, newest first. A damaged line, even one with broken UTF-8, is skipped.
    public func all() -> [Transcript] {
        let decoder = Self.decoder()
        return dayFiles().flatMap { file -> [Transcript] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(Transcript.self, from: Data($0)) }
        }
        .sorted { $0.date > $1.date }
    }

    /// Deletes day files older than the retention allows. `.none` deletes everything.
    public func prune(_ retention: DictationRetention, now: Date = Date()) {
        guard let maxAge = retention.maxAge else { return }
        guard maxAge > 0 else { deleteAll(); return }
        let oldestKept = Self.dayName(now.addingTimeInterval(-maxAge))
        for file in dayFiles() where file.deletingPathExtension().lastPathComponent < oldestKept {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func deleteAll() {
        for file in dayFiles() { try? FileManager.default.removeItem(at: file) }
    }

    private func dayFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
    }
    private static func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
