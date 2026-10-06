import Foundation

/// A received attachment with the bytes decoded from the message body.
///
/// This type is deliberately independent of either mail backend. Callers can obtain the raw
/// message from Apple Mail's local store or from Jevcast's own store, then use this value for
/// preview, opening, or saving.
public struct MailReceivedAttachmentFile: Equatable, Sendable {
    public let name: String
    public let mimeType: String
    public let data: Data

    public init(name: String, mimeType: String, data: Data) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }
}

/// Errors that are safe to show to a user without exposing source paths or credentials.
public enum MailReceivedAttachmentError: Error, Equatable, Sendable {
    case malformedMessage
    case sourceChanged
    case bodyUnavailable
    case invalidFilename
    case stagingFailed
}

extension MailReceivedAttachmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedMessage: return "This message's attachments could not be read."
        case .sourceChanged: return "This message moved or changed before its attachment could be read. Open it again and retry."
        case .bodyUnavailable: return "The message body is not available on this Mac."
        case .invalidFilename: return "This attachment has no usable filename."
        case .stagingFailed: return "The attachment could not be prepared safely."
        }
    }
}

/// Pure attachment extraction and filename handling.
public enum MailReceivedAttachmentExtractor {
    /// Extracts files from a raw RFC 5322 message and checks that its attachment metadata still
    /// matches the detail shown in the reader. The returned bytes are the exact decoded MIME
    /// bytes, including zero bytes and non-UTF8 content.
    public static func extract(rawMessage: Data, expected: MIMEMessage) throws -> [MailReceivedAttachmentFile] {
        guard let parsed = MIMEMessage.parse(rawMessage) else { throw MailReceivedAttachmentError.malformedMessage }
        guard parsed == expected else { throw MailReceivedAttachmentError.sourceChanged }
        let files = MIMEMessage.files(rawMessage).map { MailReceivedAttachmentFile(name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        guard files.count == expected.attachments.count else { throw MailReceivedAttachmentError.sourceChanged }
        for (file, metadata) in zip(files, expected.attachments) {
            guard file.name == metadata.name,
                  file.mimeType.caseInsensitiveCompare(metadata.mimeType) == .orderedSame,
                  file.data.count == metadata.size else { throw MailReceivedAttachmentError.sourceChanged }
        }
        return files
    }

    /// Produces a single path component suitable for a staging directory or save-panel default.
    /// A path supplied by a sender is never used as a path. Only its final component survives;
    /// separators, NULs, controls, and traversal components are discarded.
    public static func safeFilename(_ name: String, fallback: String = "attachment") -> String {
        func component(_ input: String) -> String {
            let normalized = input.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\\", with: "/")
            let last = normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            let scalars = last.unicodeScalars.filter { scalar in
                let value = scalar.value
                let bidiOverride = (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
                return value >= 0x20 && value != 0x7F && !bidiOverride
            }
            let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
            return result == "." || result == ".." ? "" : result
        }
        var result = component(name)
        if result.isEmpty { result = component(fallback) }
        if result.isEmpty { result = "attachment" }

        // Keep a filename within the normal single-component limit without splitting a UTF-8
        // sequence. The suffix is retained where possible, because it helps Quick Look choose a
        // previewer and the default application.
        let limit = 240
        if result.utf8.count > limit {
            let url = URL(fileURLWithPath: result)
            let ext = url.pathExtension
            let suffix = ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext
            let prefixLimit = max(1, limit - suffix.utf8.count)
            var prefix = result
            while prefix.utf8.count > prefixLimit { prefix.removeLast() }
            result = prefix + suffix
        }
        return result
    }

    /// Sanitizes names and adds a stable numeric suffix to duplicates.
    public static func uniqueFilenames(_ names: [String]) -> [String] {
        var used = Set<String>(), nextNumber: [String: Int] = [:]
        return names.map { original in
            let safe = safeFilename(original)
            let key = safe.precomposedStringWithCanonicalMapping.lowercased()
            var candidate = safe
            var number = nextNumber[key] ?? 1
            while used.contains(candidate.precomposedStringWithCanonicalMapping.lowercased()) {
                number += 1
                let url = URL(fileURLWithPath: safe)
                let ext = url.pathExtension
                let stem = ext.isEmpty ? safe : String(safe.dropLast(ext.count + 1))
                candidate = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            }
            nextNumber[key] = number
            used.insert(candidate.precomposedStringWithCanonicalMapping.lowercased())
            return candidate
        }
    }
}

/// Owner-only temporary storage for received attachment bytes.
///
/// The directory and every file are created with restrictive permissions, opened without
/// following symlinks, and removed when the staging object is released or explicitly cleaned.
public final class MailReceivedAttachmentStaging: @unchecked Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let mimeType: String
        public let size: Int
        public let url: URL

        public init(id: UUID = UUID(), name: String, mimeType: String, size: Int, url: URL) {
            self.id = id; self.name = name; self.mimeType = mimeType; self.size = size; self.url = url
        }
    }

    public let directory: URL
    private let lock = NSLock()
    private var cleaned = false

    public init(parent: URL = FileManager.default.temporaryDirectory) throws {
        let directory = parent.appendingPathComponent("jevcast-mail-attachments-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: directory.path)
            guard Self.permissions(of: directory) == 0o700 else { throw MailReceivedAttachmentError.stagingFailed }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error is MailReceivedAttachmentError ? error : MailReceivedAttachmentError.stagingFailed
        }
        self.directory = directory
    }

    deinit { cleanup() }

    public func stage(_ files: [MailReceivedAttachmentFile]) throws -> [Item] {
        let names = MailReceivedAttachmentExtractor.uniqueFilenames(files.map(\.name))
        var staged: [Item] = []
        do {
            for (index, file) in files.enumerated() {
                let name = names[index]
                let url = directory.appendingPathComponent(name, isDirectory: false)
                guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                      url.lastPathComponent == name else { throw MailReceivedAttachmentError.stagingFailed }
                try write(file.data, to: url)
                staged.append(Item(name: name, mimeType: file.mimeType, size: file.data.count, url: url))
            }
            return staged
        } catch let error as MailReceivedAttachmentError {
            cleanupFiles(staged.map(\.url))
            throw error
        } catch {
            cleanupFiles(staged.map(\.url))
            throw MailReceivedAttachmentError.stagingFailed
        }
    }

    public func cleanup() {
        lock.lock(); defer { lock.unlock() }
        guard !cleaned else { return }
        cleaned = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func cleanupFiles(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MailReceivedAttachmentError.stagingFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size == off_t(data.count), (info.st_mode & 0o777) == 0o600 else {
                try? handle.close(); throw MailReceivedAttachmentError.stagingFailed
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error is MailReceivedAttachmentError ? error : MailReceivedAttachmentError.stagingFailed
        }
    }

    private static func permissions(of url: URL) -> Int16? {
        guard let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else { return nil }
        return Int16(truncating: mode) & 0o777
    }
}
