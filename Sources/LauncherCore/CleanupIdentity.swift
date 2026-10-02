import Darwin
import Foundation

/// Kernel identity, not a process title. Arguments stay in memory and are never displayed.
public struct CleanupIdentity: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public let path: String
    public let arguments: [String]?

    public init(pid: Int32, ppid: Int32, uid: UInt32, startedSeconds: UInt64, startedMicroseconds: UInt64,
                path: String, arguments: [String]?) {
        self.pid = pid; self.ppid = ppid; self.uid = uid
        self.startedSeconds = startedSeconds; self.startedMicroseconds = startedMicroseconds
        self.path = path; self.arguments = arguments
    }

    public func sameProcess(as other: CleanupIdentity) -> Bool {
        pid == other.pid && uid == other.uid && startedSeconds == other.startedSeconds
            && startedMicroseconds == other.startedMicroseconds && path == other.path && arguments == other.arguments
    }

    public static func read(_ pid: Int32) -> CleanupIdentity? {
        guard pid > 1, let before = info(pid) else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let arguments = readArguments(pid)
        guard let after = info(pid), before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec, before.pbi_ppid == after.pbi_ppid,
              before.pbi_uid == after.pbi_uid else { return nil }
        return CleanupIdentity(pid: pid, ppid: Int32(after.pbi_ppid), uid: after.pbi_uid,
                               startedSeconds: after.pbi_start_tvsec, startedMicroseconds: after.pbi_start_tvusec,
                               path: String(cString: path), arguments: arguments)
    }

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size ? value : nil
    }

    private static func readArguments(_ pid: Int32) -> [String]? {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &maximum, &size, nil, 0) == 0, maximum > 0, maximum <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(maximum))
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        size = bytes.count
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Array(bytes.prefix(size)))
    }

    /// KERN_PROCARGS2: argc, executable path, padding, then exactly argc NUL-terminated arguments.
    static func parseArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        var count: Int32 = 0
        withUnsafeMutableBytes(of: &count) { $0.copyBytes(from: bytes.prefix(4)) }
        guard count > 0, count <= 16_384 else { return nil }
        var cursor = 4
        guard let pathEnd = bytes[cursor...].firstIndex(of: 0) else { return nil }
        cursor = pathEnd + 1
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            arguments.append(argument); cursor = end + 1
        }
        return arguments
    }
}
