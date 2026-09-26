import Darwin
import Foundation

/// Owner-only file access for automation state: no symlinks, bounded reads, atomic writes.
enum SecureFile {
    static let maxJSON = 2 * 1024 * 1024
    static let maxOutput = 5 * 1024 * 1024

    /// Creates the folder (0700) if missing, then checks it is a real folder owned by this user.
    static func ensureDirectory(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            guard errno == ENOENT else { throw AutomationStoreError.io("Cannot read \(url.path): \(errno)") }
            if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw AutomationStoreError.io("Cannot create \(url.path): \(errno)") }
            guard lstat(url.path, &st) == 0 else { throw AutomationStoreError.io("Cannot read \(url.path)") }
        }
        try checkNode(st, url.path, directory: true)
        if st.st_mode & 0o077 != 0 { chmod(url.path, 0o700) }
    }

    /// Checks an existing folder without creating it. False when missing.
    static func isDirectory(_ url: URL) throws -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        try checkNode(st, url.path, directory: true)
        return true
    }

    static func checkNode(_ st: stat, _ path: String, directory: Bool) throws {
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { throw AutomationStoreError.symlink(path) }
        if directory ? type != S_IFDIR : type != S_IFREG { throw AutomationStoreError.notRegularFile(path) }
        if st.st_uid != getuid() { throw AutomationStoreError.notOwned(path) }
    }

    /// Reads a regular file without following a symlink. Nil when missing.
    static func read(_ url: URL, maxBytes: Int) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw AutomationStoreError.symlink(url.path) }
            throw AutomationStoreError.io("Cannot open \(url.lastPathComponent): \(errno)")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw AutomationStoreError.io("Cannot stat \(url.lastPathComponent)") }
        try checkNode(st, url.path, directory: false)
        guard st.st_size <= maxBytes else { throw AutomationStoreError.tooLarge(url.lastPathComponent) }
        var data = Data(count: Int(st.st_size))
        var done = 0
        while done < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + done, $0.count - done) }
            if n <= 0 { break }
            done += n
        }
        return data.prefix(done)
    }

    /// Writes a temporary file (0600) beside the target, syncs it, and renames it into place.
    static func write(_ data: Data, to url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFLNK { throw AutomationStoreError.symlink(url.path) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AutomationStoreError.io("Cannot write \(url.lastPathComponent): \(errno)") }
        var ok = true
        data.withUnsafeBytes { buf in
            var done = 0
            while done < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + done, buf.count - done)
                if n <= 0 { ok = false; break }
                done += n
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        guard ok, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw AutomationStoreError.io("Cannot save \(url.lastPathComponent): \(errno)")
        }
    }

    /// A single safe file name inside a run folder: no separators, no dot-dot, no hidden names.
    static func isSafeName(_ name: String) -> Bool {
        (1...128).contains(name.count) && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }
}
