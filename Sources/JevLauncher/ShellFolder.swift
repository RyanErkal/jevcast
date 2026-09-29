import Darwin
import Foundation

/// The folder the Terminal view's shell is in, read from the process table. libghostty starts
/// the shell through /usr/bin/login, so the shell is the child of Jevcast's login process.
/// Nothing is sent to or read from the shell itself.
enum ShellFolder {
    static func current() -> URL? {
        guard let login = children(of: getpid()).first(where: { path(of: $0) == "/usr/bin/login" }) else { return nil }
        let shell = children(of: login).first ?? login
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(shell, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let folder = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return folder.isEmpty ? nil : URL(fileURLWithPath: folder, isDirectory: true)
    }

    /// The folder as the shell writes it, with the home folder as ~.
    static func display(_ folder: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
