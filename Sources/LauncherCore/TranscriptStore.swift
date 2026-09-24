import Foundation

/// One dictation, as stored. Text only; audio is never kept.
public struct Transcript: Codable, Equatable, Sendable {
    public let text: String
    public let date: Date
    /// Seconds the key was held.
    public let duration: TimeInterval
    /// Bundle ID of the app the text went to, when known.
    public let target: String?
    /// "apple-speech", or "apple-speech+luna" when Luna cleaned the text.
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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(Self.dayName(transcript.date) + ".jsonl")
        var line = try Self.encoder().encode(transcript)
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file, options: [.atomic])
            // Only this user may read the history.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Every entry, newest first. A damaged line is skipped.
    public func all() -> [Transcript] {
        let decoder = Self.decoder()
        return dayFiles().flatMap { file -> [Transcript] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? decoder.decode(Transcript.self, from: Data($0.utf8)) }
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
