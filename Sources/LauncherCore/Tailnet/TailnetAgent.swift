import Foundation

/// What the Jevcast agent on another device reports: its load, the ports it listens on, and what it
/// shares with `tailscale serve`. `scripts/tailnet-agent.ps1` is the agent for Windows.
public struct TailnetReport: Equatable, Sendable {
    public struct Listener: Equatable, Sendable {
        public let port: Int
        public let process: String
        public init(port: Int, process: String) { self.port = port; self.process = process }
    }
    public let os: String?
    public let stats: DeviceStats
    /// TCP ports that other devices can reach: bound to every address or to a Tailscale address.
    public let listeners: [Listener]
    public let shares: [TailnetShare]

    public init(os: String? = nil, stats: DeviceStats, listeners: [Listener] = [], shares: [TailnetShare] = []) {
        self.os = os; self.stats = stats; self.listeners = listeners; self.shares = shares
    }
}

public enum TailnetAgent {
    /// The agent listens on 127.0.0.1 at this port, and `tailscale serve` shares it on the tailnet at the same port.
    public static let port = 61209
    public static let path = "/v1/status"
    /// Ports tried on a device without the agent.
    public static let commonPorts = [80, 443, 3000, 3001, 4000, 5173, 8000, 8080, 8443, 8888]
    /// At most this many ports are checked on one device.
    static let maxPorts = 48
    /// Processes whose ports are not pages: Windows services, file sharing, and Tailscale itself.
    static let skippedProcesses: Set<String> = ["system", "idle", "svchost", "lsass", "wininit", "services", "spoolsv",
                                                "tailscaled", "tailscale-ipn", "tailscale"]

    /// The report, or nil when the answer is not from the Jevcast agent.
    public static func parse(_ data: Data) -> TailnetReport? {
        guard let raw = try? JSONDecoder().decode(RawReport.self, from: data), raw.agent == "jevcast" else { return nil }
        let stats = DeviceStats(cpuPercent: raw.cpuPercent, memoryUsed: raw.memoryUsedBytes, memoryTotal: raw.memoryTotalBytes,
                                disks: (raw.disks ?? []).map { DeviceStats.Disk(name: $0.name ?? "", total: $0.totalBytes ?? 0, free: $0.freeBytes ?? 0) },
                                uptime: raw.uptimeSeconds)
        let listeners = (raw.listening ?? []).compactMap { item -> TailnetReport.Listener? in
            guard let port = item.port, (1...65_535).contains(port) else { return nil }
            return TailnetReport.Listener(port: port, process: item.process ?? "")
        }
        return TailnetReport(os: raw.os, stats: stats, listeners: listeners, shares: raw.serve.map(TailnetServe.shares) ?? [])
    }

    /// The ports to check on a device: the agent's listeners and shares, or the common ports without an agent.
    /// Service and Tailscale ports, and the agent's own, are left out.
    public static func portsToCheck(_ report: TailnetReport?) -> [Int] {
        guard let report else { return commonPorts }
        let listened = report.listeners.filter { !skippedProcesses.contains(processName($0.process)) }.map(\.port)
        return Array(Set(listened + report.shares.map(\.port)).subtracting([port])).sorted().prefix(maxPorts).map { $0 }
    }

    /// The ports of a device's shares, to read their titles.
    public static func sharePorts(_ shares: [TailnetShare]) -> [Int] {
        Array(Set(shares.map(\.port)).subtracting([port])).sorted().prefix(maxPorts).map { $0 }
    }

    /// "Svchost.exe" reads as "svchost".
    static func processName(_ text: String) -> String {
        let lower = text.lowercased()
        return lower.hasSuffix(".exe") ? String(lower.dropLast(4)) : lower
    }
}

private struct RawReport: Decodable {
    struct Disk: Decodable { let name: String?; let totalBytes: Double?; let freeBytes: Double? }
    struct Listener: Decodable { let port: Int?; let process: String? }
    let agent: String?
    let os: String?
    let uptimeSeconds: Double?
    let cpuPercent: Double?
    let memoryTotalBytes: Double?
    let memoryUsedBytes: Double?
    let disks: [Disk]?
    let listening: [Listener]?
    let serve: ServeConfig?
}
