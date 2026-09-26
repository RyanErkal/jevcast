import Darwin
import Foundation

/// Owner-only state files, opened relative to directories that cannot follow links.
enum SecureFile {
    static let maxJSON = 2 * 1024 * 1024
    static let maxOutput = 5 * 1024 * 1024

    /// Only these system-owned aliases are accepted. User-controlled links are never resolved.
    private static func systemPath(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
        guard let parts = SafeFS.components(systemPath(url.path)) else { throw AutomationStoreError.io("Invalid folder path.") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw AutomationStoreError.io("Cannot open the root folder.") }
        do {
            for part in parts {
                if create, mkdirat(fd, part, 0o700) != 0, errno != EEXIST {
                    throw AutomationStoreError.io("Cannot create folder: \(errno)")
                }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AutomationStoreError.io("Cannot open folder without symbolic links: \(errno)") }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    static func ensureParents(of url: URL) throws {
        let fd = try directory(url.deletingLastPathComponent(), create: true)
        close(fd)
    }

    static func ensureDirectory(_ url: URL) throws {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        if mkdirat(parent, url.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw AutomationStoreError.io("Cannot create folder: \(errno)")
        }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AutomationStoreError.io("Cannot open folder without symbolic links: \(errno)") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw AutomationStoreError.io("Cannot stat folder.") }
        try checkNode(st, url.path, directory: true)
        guard fchmod(fd, 0o700) == 0 else { throw AutomationStoreError.io("Cannot protect folder.") }
    }

    static func isDirectory(_ url: URL) throws -> Bool {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        var st = stat()
        guard fstatat(parent, url.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw AutomationStoreError.io("Cannot stat folder: \(errno)")
        }
        try checkNode(st, url.path, directory: true)
        return true
    }

    static func checkNode(_ st: stat, _ path: String, directory: Bool) throws {
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { throw AutomationStoreError.symlink(path) }
        if directory ? type != S_IFDIR : type != S_IFREG { throw AutomationStoreError.notRegularFile(path) }
        if st.st_uid != getuid() { throw AutomationStoreError.notOwned(path) }
        if !directory, st.st_nlink != 1 { throw AutomationStoreError.io("Hard-linked state files are not supported.") }
    }

    static func read(_ url: URL, maxBytes: Int) throws -> Data? {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw AutomationStoreError.symlink(url.path) }
            throw AutomationStoreError.io("Cannot open \(url.lastPathComponent): \(errno)")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw AutomationStoreError.io("Cannot stat \(url.lastPathComponent)") }
        try checkNode(st, url.path, directory: false)
        guard st.st_size >= 0, st.st_size <= maxBytes else { throw AutomationStoreError.tooLarge(url.lastPathComponent) }
        var data = Data(count: Int(st.st_size))
        var done = 0
        while done < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + done, $0.count - done) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw AutomationStoreError.io("File changed or could not be read.") }
            done += n
        }
        return data
    }

    /// Create, sync and rename within the same open parent. Both file and directory are synced.
    static func write(_ data: Data, to url: URL) throws {
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        var st = stat()
        if fstatat(parent, url.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            try checkNode(st, url.path, directory: false)
        } else if errno != ENOENT { throw AutomationStoreError.io("Cannot inspect destination.") }
        let temp = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let fd = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AutomationStoreError.io("Cannot write \(url.lastPathComponent): \(errno)") }
        defer { close(fd); unlinkat(parent, temp, 0) }
        var ok = true
        data.withUnsafeBytes { buf in
            var done = 0
            while done < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + done, buf.count - done)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { ok = false; break }
                done += n
            }
        }
        guard ok, fsync(fd) == 0, renameat(parent, temp, parent, url.lastPathComponent) == 0, fsync(parent) == 0 else {
            throw AutomationStoreError.io("Cannot save \(url.lastPathComponent): \(errno)")
        }
    }

    static func acquireLock(in root: URL) throws -> Int32? {
        let parent = try directory(root)
        defer { close(parent) }
        let fd = openat(parent, "runner.lock", O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AutomationStoreError.io("Cannot open runner lock.") }
        do {
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw AutomationStoreError.io("Cannot stat runner lock.") }
            try checkNode(st, "runner.lock", directory: false)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
            return fd
        } catch { close(fd); throw error }
    }

    static func isSafeName(_ name: String) -> Bool {
        (1...128).contains(name.count) && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }
}
