import Foundation

/// One `~/.codex/automations/<id>/automation.toml`, read only. Entries that fail to parse stay visible with `error`.
public struct CodexAutomation: Equatable, Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case active, paused, other(String)
        init(_ raw: String) { self = raw == "ACTIVE" ? .active : raw == "PAUSED" ? .paused : .other(raw) }
    }
    public var id: String
    public var name: String
    public var kind: String
    public var status: Status
    /// As written in the file, with any "RRULE:" prefix.
    public var rrule: String
    public var prompt: String
    public var notificationPolicy: String?
    public var targetThreadID: String?
    /// Milliseconds since 1970.
    public var createdAt: Int64?
    public var updatedAt: Int64?
    public var path: String
    /// SHA-256 hex of the file bytes. Empty when the file could not be read.
    public var hash: String
    public var error: String?

    public init(id: String, name: String = "", kind: String = "", status: Status = .other(""), rrule: String = "", prompt: String = "",
                notificationPolicy: String? = nil, targetThreadID: String? = nil, createdAt: Int64? = nil, updatedAt: Int64? = nil,
                path: String, hash: String = "", error: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.status = status; self.rrule = rrule; self.prompt = prompt
        self.notificationPolicy = notificationPolicy; self.targetThreadID = targetThreadID; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.path = path; self.hash = hash; self.error = error
    }
}

public enum CodexImport {
    public static let supportedVersion: Int64 = 1
    static let maxFileBytes = 1024 * 1024

    /// Reads every `<folder>/*/automation.toml`. Never writes. Sorted by ID.
    public static func readAll(folder: URL) -> [CodexAutomation] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let dir = folder.appendingPathComponent(name)
            guard let type = fileType(dir.path) else { return nil }
            let file = dir.appendingPathComponent("automation.toml").path
            if type == S_IFLNK { return CodexAutomation(id: name, path: file, error: "Folder is a symbolic link") }
            guard type == S_IFDIR else { return nil }
            return read(path: file, folderName: name)
        }
    }

    /// Parses one file. `folderName` must match the file's `id`.
    public static func read(path: String, folderName: String) -> CodexAutomation {
        var entry = CodexAutomation(id: folderName, path: path)
        guard let type = fileType(path) else { entry.error = "File not found"; return entry }
        guard type == S_IFREG else { entry.error = type == S_IFLNK ? "File is a symbolic link" : "Not a regular file"; return entry }
        guard let data = readBounded(path) else { entry.error = "File is unreadable or too large"; return entry }
        entry.hash = Sha256.hex(data)
        guard let text = String(data: data, encoding: .utf8) else { entry.error = "File is not UTF-8"; return entry }
        let table: [String: TomlValue]
        do { table = try TomlLite.parse(text) } catch { entry.error = "\(error)"; return entry }
        do { try fill(&entry, from: table, folderName: folderName) } catch { entry.error = "\(error)" }
        return entry
    }

    /// True when the source is ACTIVE, or cannot be read and parsed. Fails closed so a port never double-runs.
    public static func isActiveInCodex(path: String) -> Bool {
        let folderName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        let entry = read(path: path, folderName: folderName)
        return entry.error != nil || entry.status == .active
    }

    private struct FieldError: Error, CustomStringConvertible { var description: String }

    private static func fill(_ e: inout CodexAutomation, from t: [String: TomlValue], folderName: String) throws {
        func string(_ key: String) throws -> String {
            guard let v = try optionalString(key) else { throw FieldError(description: "Missing \(key)") }
            return v
        }
        func optionalString(_ key: String) throws -> String? {
            switch t[key] {
            case .string(let s): return s
            case nil: return nil
            default: throw FieldError(description: "\(key) must be a string")
            }
        }
        func int(_ key: String) throws -> Int64? {
            switch t[key] {
            case .integer(let v): return v
            case nil: return nil
            default: throw FieldError(description: "\(key) must be an integer")
            }
        }
        guard let version = try int("version") else { throw FieldError(description: "Missing version") }
        guard version == supportedVersion else { throw FieldError(description: "Unsupported version \(version)") }
        let id = try string("id")
        guard id == folderName else { throw FieldError(description: "ID does not match its folder") }
        e.id = id
        e.name = try string("name")
        e.kind = try string("kind")
        e.status = .init(try string("status"))
        e.rrule = try string("rrule")
        e.prompt = try string("prompt")
        e.notificationPolicy = try optionalString("notification_policy")
        e.targetThreadID = try optionalString("target_thread_id")
        e.createdAt = try int("created_at")
        e.updatedAt = try int("updated_at")
    }

    static func fileType(_ path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    /// Opens without following a final symlink and reads at most `maxFileBytes`.
    private static func readBounded(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maxFileBytes + 1), data.count <= maxFileBytes else { return nil }
        return data
    }
}
