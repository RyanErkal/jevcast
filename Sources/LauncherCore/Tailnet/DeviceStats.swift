import Foundation

/// Load figures for one device. Nil means not known.
public struct DeviceStats: Equatable, Sendable {
    public struct Disk: Equatable, Sendable {
        /// "C:" on Windows; empty for this Mac's one volume.
        public let name: String
        public let total: Double
        public let free: Double
        public init(name: String, total: Double, free: Double) { self.name = name; self.total = total; self.free = free }
    }
    public var cpuPercent: Double?
    public var memoryUsed: Double?
    public var memoryTotal: Double?
    public var disks: [Disk]
    public var uptime: TimeInterval?

    public init(cpuPercent: Double? = nil, memoryUsed: Double? = nil, memoryTotal: Double? = nil, disks: [Disk] = [], uptime: TimeInterval? = nil) {
        self.cpuPercent = cpuPercent; self.memoryUsed = memoryUsed; self.memoryTotal = memoryTotal; self.disks = disks; self.uptime = uptime
    }

    /// "CPU 12% · Memory 9.8 of 32 GB · C: 120 GB free · up 3 d 4 h". Unknown figures are left out.
    public var summary: String {
        var parts: [String] = []
        if let cpuPercent { parts.append("CPU \(Int(min(max(cpuPercent, 0), 100).rounded()))%") }
        if let memoryUsed, let memoryTotal, memoryTotal > 0 {
            parts.append("Memory \(Self.gigabytes(memoryUsed)) of \(Self.size(memoryTotal))")
        }
        let disks = self.disks.filter { $0.total > 0 }
        if !disks.isEmpty {
            parts.append(disks.map { ($0.name.isEmpty ? "Disk" : $0.name) + " " + Self.size($0.free) + " free" }.joined(separator: ", "))
        }
        if let uptime, uptime > 0 { parts.append("up " + Self.duration(uptime)) }
        return parts.joined(separator: " · ")
    }

    /// Binary units, as Windows and Activity Monitor show memory: "9.8 GB", "32 GB", "1.8 TB".
    public static func size(_ bytes: Double) -> String {
        let gib = bytes / 1_073_741_824
        return gib >= 1024 ? trimmed(gib / 1024) + " TB" : gigabytes(bytes) + " GB"
    }

    /// The number of GB without the unit, with one decimal under 100.
    static func gigabytes(_ bytes: Double) -> String { trimmed(bytes / 1_073_741_824) }

    private static func trimmed(_ value: Double) -> String {
        if value >= 100 { return String(Int(value.rounded())) }
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// "3 d 4 h", "4 h 12 min", "12 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return rest > 0 ? "\(hours) h \(rest) min" : "\(hours) h" }
        return "\(max(rest, 1)) min"
    }
}
