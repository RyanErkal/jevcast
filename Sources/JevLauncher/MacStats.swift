import Darwin
import Foundation
import LauncherCore

/// This Mac's CPU, memory, disk, and uptime, read from the kernel. No commands and no network.
enum MacStats {
    static func read() async -> DeviceStats {
        let cpu = await CPULoad.shared.percent()
        let memory = usedMemory()
        let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let disks = volume.flatMap { values -> [DeviceStats.Disk]? in
            guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
            return [DeviceStats.Disk(name: "", total: Double(total), free: Double(free))]
        } ?? []
        return DeviceStats(cpuPercent: cpu, memoryUsed: memory, memoryTotal: memory == nil ? nil : Double(ProcessInfo.processInfo.physicalMemory),
                           disks: disks, uptime: uptime())
    }

    /// App memory, wired, and compressed, as Activity Monitor counts Memory Used.
    private static func usedMemory() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return Double(pages) * Double(vm_kernel_page_size)
    }

    /// Time since the Mac started, sleep included.
    private static func uptime() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }
}

/// The busy share of CPU time since the last reading. The first reading takes a second sample shortly after.
final class CPULoad: @unchecked Sendable {
    static let shared = CPULoad()
    private let lock = NSLock()
    private var last: [UInt32]?

    func percent() async -> Double? {
        if lock.withLock({ last == nil }) {
            _ = sample()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return sample()
    }

    private func sample() -> Double? {
        guard let ticks = Self.ticks() else { return nil }
        return lock.withLock {
            defer { last = ticks }
            guard let last else { return nil }
            // User, system, idle, nice. The counters wrap.
            let delta = zip(ticks, last).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            return total > 0 ? (total - delta[2]) / total * 100 : nil
        }
    }

    private static func ticks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }
}
