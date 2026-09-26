import Foundation

/// Small POSIX helpers for proposals: no-follow lookups, descriptor-relative opens, and identities.
enum SafeFS {
    /// Components of an absolute path. Nil when the path is not in plain canonical form
    /// (relative, empty parts, ".", "..", NUL, or a trailing slash).
    static func components(_ path: String) -> [String]? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        if path == "/" { return [] }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    /// A comparison key for a path on a case- and normalization-insensitive volume.
    static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    static func join(_ parts: [String]) -> String { "/" + parts.joined(separator: "/") }

    /// Component-wise: "/a/b" is inside "/a", "/a2" is not. A path is inside itself.
    static func isInside(_ path: [String], _ root: [String]) -> Bool {
        path.count >= root.count && Array(path.prefix(root.count)) == root
    }

    static func identity(_ st: stat) -> FileIdentity {
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return FileIdentity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino),
                            isDirectory: st.st_mode & S_IFMT == S_IFDIR, size: UInt64(max(0, st.st_size)),
                            modified: Date(timeIntervalSince1970: mtime), linkCount: UInt64(st.st_nlink))
    }

    static func lstatPath(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    /// Same object with the same content signals. Link count is left out: it changes when siblings do.
    static func sameObject(_ a: FileIdentity, _ b: FileIdentity) -> Bool {
        a.device == b.device && a.inode == b.inode && a.isDirectory == b.isDirectory && a.size == b.size
            && abs(a.modified.timeIntervalSince(b.modified)) < 0.000_01
    }

    /// Opens a directory by walking from "/" with O_NOFOLLOW on every component, so no symlink is followed.
    static func openDirectory(_ path: String) -> Int32? {
        guard let parts = components(path) else { return nil }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }

    static func fstatFD(_ fd: Int32) -> stat? {
        var st = stat()
        return fstat(fd, &st) == 0 ? st : nil
    }

    /// No-follow stat of a name inside an open directory. `errno` is kept when it fails.
    static func statAt(_ dirFD: Int32, _ name: String) -> stat? {
        var st = stat()
        return fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? st : nil
    }

    /// Entry names in an open directory, without "." and "..". Reads a duplicate descriptor, so `fd` stays open.
    static func names(inDirectory fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else { return nil }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
            if names.count > 64 { break }
        }
        return names
    }

    static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    static func leaf(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// Atomic write, then fsync of the file and its folder.
    static func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        for path in [url.path, url.deletingLastPathComponent().path] {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}
